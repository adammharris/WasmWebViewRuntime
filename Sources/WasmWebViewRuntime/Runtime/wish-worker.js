// The guest side of the web view backend: an in-memory filesystem and a WASI
// preview 1 implementation, running in a Web Worker.
//
// Why hand-written rather than @wasmer/wasi or browser_wasi_shim: this backend
// is defined by what it does with the filesystem, not by running wasm. It has
// to load a host directory tree, track exactly which nodes the guest touched,
// and emit a diff — and neither library exposes dirty tracking, so the sync-back
// would have to re-serialise and re-compare the whole tree every run. On an 18 MB
// standard library that is the entire performance budget. browser_wasi_shim also
// documents that the parts of preview 1 it does not implement are "either
// throwing an exception, returning an error, or incorrectly implemented", and
// @wasmer/wasi is itself a Rust-compiled wasm blob needing an npm bundling step
// this project has no toolchain for. The safety net for writing it by hand is
// `WasmBackendParityTests`, which runs the same module on both backends and
// compares stdout, exit status, and the resulting files.
//
// Everything here is synchronous. `_start` does not return until the guest
// exits, so nothing in this worker's event loop runs during a program — which
// is why output is flushed from inside `fd_write` rather than on a timer, and
// why cancellation is the page calling `terminate()` on us.

'use strict';

const KIND = { DIR: 0, FILE: 1, LINK: 2 };

// WASI preview 1 errno, which is alphabetical rather than POSIX's numbering.
const E = {
  SUCCESS: 0, ACCES: 2, AGAIN: 6, BADF: 8, EXIST: 20, FAULT: 21, INVAL: 28,
  IO: 29, ISDIR: 31, LOOP: 32, MFILE: 33, NAMETOOLONG: 37, NOENT: 44,
  NOMEM: 48, NOSPC: 51, NOSYS: 52, NOTDIR: 54, NOTEMPTY: 55, NOTSUP: 58,
  NOTTY: 59, OVERFLOW: 61, PERM: 63, PIPE: 64, RANGE: 68, SPIPE: 70,
  NOTCAPABLE: 76,
};

const FILETYPE = { UNKNOWN: 0, CHARACTER_DEVICE: 2, DIRECTORY: 3, REGULAR_FILE: 4, SYMLINK: 7 };

// What a newly created file and directory get, chosen to match WasmKit rather
// than to match convention: its WASI opens with `.ownerReadWrite` and creates
// directories with `.ownerReadWriteExecute`, so anything a wasm guest has ever
// made in this sandbox is already 0600. `WasmBackendParityTests` compares these,
// and the execute bit is the shell's trust model — the conservative value is
// also the right default for a file the user did not ask to be runnable.
const CREATE_FILE_MODE = 0o600;
const CREATE_DIR_MODE = 0o700;

const OFLAGS = { CREAT: 1, DIRECTORY: 2, EXCL: 4, TRUNC: 8 };
const FDFLAGS = { APPEND: 1, NONBLOCK: 4 };
const LOOKUP_SYMLINK_FOLLOW = 1;
const FSTFLAGS = { ATIM: 1, ATIM_NOW: 2, MTIM: 4, MTIM_NOW: 8 };

// Every right, on every descriptor. Containment here is the preopen boundary
// and the host-side path check in `WasmWriteback.apply`, not a rights mask the
// guest could only ever narrow for itself.
const ALL_RIGHTS = 0xffffffffffffffffn;

const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: false });

/// Thrown by `proc_exit`, which is the normal way a WASI program ends.
class Exit {
  constructor(code) { this.code = code; }
}

/// Thrown by a WASI call that failed. Caught at the import boundary and turned
/// back into an errno return value.
class Fail {
  constructor(errno) { this.errno = errno; }
}

// MARK: - The filesystem

let nextIno = 1;

function makeNode(kind, mode, mtime) {
  return {
    kind,
    mode,
    mtime,
    ino: nextIno++,
    parent: null,
    name: '',
    children: kind === KIND.DIR ? new Map() : null,
    // For files: `data` is the backing store and may be larger than `size`.
    // `shared` marks a view into the snapshot buffer, which is copy-on-write
    // because a cached read-only mount hands the same buffer to every run.
    data: null,
    size: 0,
    shared: false,
    target: null,
    // Set on creation and on every mutation. This is what the sync-back reads,
    // and the reason for not using an off-the-shelf WASI shim.
    dirty: false,
  };
}

function link(parent, name, node) {
  node.parent = parent;
  node.name = name;
  parent.children.set(name, node);
  return node;
}

function pathOf(node) {
  const parts = [];
  for (let n = node; n && n.parent; n = n.parent) parts.push(n.name);
  return parts.reverse().join('/');
}

/// One preopen: a tree, plus the set of paths it started with so deletions can
/// be derived by difference at the end.
class Tree {
  constructor(index, guestPath, readOnly) {
    this.index = index;
    this.guestPath = guestPath;
    this.readOnly = readOnly;
    this.root = makeNode(KIND.DIR, 0o755, Date.now() / 1000);
    this.original = new Set();
  }

  /// Reads a `WSHF` blob. File bodies are `subarray` views rather than copies:
  /// an 18 MB tree costs one buffer, not two, and the copy only happens for
  /// the handful of files the guest actually writes to.
  load(buffer) {
    const view = new DataView(buffer);
    const bytes = new Uint8Array(buffer);
    if (view.getUint32(0, false) !== 0x57534846 /* "WSHF" */) throw new Error('bad snapshot magic');
    if (view.getUint32(4, true) !== 1) throw new Error('bad snapshot version');

    const count = view.getUint32(8, true);
    let o = 12;
    for (let i = 0; i < count; i++) {
      const kind = view.getUint8(o); o += 1;
      const pathLen = view.getUint32(o, true); o += 4;
      const dataLen = view.getUint32(o, true); o += 4;
      const mode = view.getUint32(o, true); o += 4;
      const mtime = view.getFloat64(o, true); o += 8;
      const path = decoder.decode(bytes.subarray(o, o + pathLen)); o += pathLen;
      const body = bytes.subarray(o, o + dataLen); o += dataLen;

      // Entries arrive sorted, which puts every parent ahead of its children.
      const slash = path.lastIndexOf('/');
      const parent = slash < 0 ? this.root : this.nodeAt(path.slice(0, slash));
      if (!parent || parent.kind !== KIND.DIR) continue;
      const name = slash < 0 ? path : path.slice(slash + 1);

      const node = makeNode(kind, mode, mtime);
      if (kind === KIND.FILE) {
        node.data = body;
        node.size = dataLen;
        node.shared = true;
      } else if (kind === KIND.LINK) {
        node.target = decoder.decode(body);
      }
      link(parent, name, node);
      this.original.add(path);
    }
  }

  nodeAt(path) {
    let node = this.root;
    for (const part of path.split('/')) {
      if (!part || node.kind !== KIND.DIR) return null;
      node = node.children.get(part);
      if (!node) return null;
    }
    return node;
  }

  /// Walks `path` from `base`, following symlinks.
  ///
  /// Returns the parent directory, the final component's name, and the node if
  /// it exists — `path_open` with `O_CREAT` needs the first two even when the
  /// third is null. `..` clamps at the tree root, so no amount of it walks out
  /// of a preopen; that is the same rule `SandboxPath` applies on the host, and
  /// the host applies it again on every write-back.
  resolve(base, path, followFinal) {
    let node = base;
    let parent = base.parent;
    let name = base.name;
    let links = 0;

    const stack = [];
    const push = (p) => {
      const parts = p.split('/');
      for (let i = parts.length - 1; i >= 0; i--) {
        if (parts[i] && parts[i] !== '.') stack.push(parts[i]);
      }
    };
    if (path.startsWith('/')) node = this.root;
    push(path);

    while (stack.length) {
      const part = stack.pop();
      if (part === '..') {
        node = node.parent || this.root;
        parent = node.parent;
        name = node.name;
        continue;
      }
      if (node.kind !== KIND.DIR) throw new Fail(E.NOTDIR);

      parent = node;
      name = part;
      const child = node.children.get(part);
      const isFinal = stack.length === 0;

      if (!child) {
        if (!isFinal) throw new Fail(E.NOENT);
        return { parent, name, node: null };
      }
      if (child.kind === KIND.LINK && (!isFinal || followFinal)) {
        if (++links > 32) throw new Fail(E.LOOP);
        if (child.target.startsWith('/')) node = this.root;
        push(child.target);
        continue;
      }
      node = child;
    }
    return { parent, name, node };
  }

  /// The `WSHW` diff: every node created or mutated, plus every path that was
  /// in the snapshot and is not in the tree now.
  collect(changes, deletions) {
    if (this.readOnly) return;

    const present = new Set();
    const visit = (node) => {
      const path = pathOf(node);
      if (node !== this.root) {
        present.add(path);
        if (node.dirty) changes.push({ preopen: this.index, path, node });
      }
      if (node.kind === KIND.DIR) for (const child of node.children.values()) visit(child);
    };
    visit(this.root);

    for (const path of this.original) {
      if (!present.has(path)) deletions.push({ preopen: this.index, path });
    }
  }
}

function touch(node) {
  node.dirty = true;
  node.mtime = Date.now() / 1000;
}

function writeInto(node, offset, bytes) {
  const end = offset + bytes.length;
  if (node.shared || !node.data || node.data.length < end) {
    const capacity = Math.max(end, (node.data ? node.data.length : 0) * 2, 64);
    const next = new Uint8Array(capacity);
    if (node.data) next.set(node.data.subarray(0, node.size));
    node.data = next;
    node.shared = false;
  }
  // A seek past the end leaves a hole, which POSIX says reads as zeroes. A
  // reallocation already gave us those; an in-place write may not have.
  if (offset > node.size) node.data.fill(0, node.size, offset);
  node.data.set(bytes, offset);
  if (end > node.size) node.size = end;
  touch(node);
}

// MARK: - Standard streams

/// stdout and stderr share one sink, so their interleaving reaches the terminal
/// in the order the guest produced it — the same thing the interpreter backend
/// gets by pointing both at one pipe.
class Output {
  constructor() {
    this.buffer = [];
    this.pending = 0;
    this.lastFlush = 0;
  }

  write(bytes) {
    this.buffer.push(bytes.slice());
    this.pending += bytes.length;
    // Nothing else in this worker runs while the guest does, so a timer would
    // never fire — the flush decision has to be made here, on every write.
    // 8 KB bounds the postMessage traffic of a chatty program; 16 ms keeps a
    // slow one feeling live.
    const now = Date.now();
    if (this.pending >= 8192 || now - this.lastFlush >= 16) this.flush();
  }

  flush() {
    if (!this.pending) return;
    const merged = new Uint8Array(this.pending);
    let o = 0;
    for (const chunk of this.buffer) { merged.set(chunk, o); o += chunk.length; }
    this.buffer = [];
    this.pending = 0;
    this.lastFlush = Date.now();
    postMessage({ type: 'output', bytes: merged.buffer }, [merged.buffer]);
  }
}

/// A blocking read of the host's stdin, over a synchronous XHR.
///
/// WASI's `fd_read` is synchronous and the guest is mid-call, so the bytes have
/// to arrive without the event loop turning. The usual answer is `Atomics.wait`
/// on a `SharedArrayBuffer`, which is unavailable: a WKWebView cannot become
/// cross-origin isolated, because COOP and COEP cannot be set on a document
/// served by a `WKURLSchemeHandler`.
///
/// A synchronous `XMLHttpRequest` does the same job. It is forbidden on a
/// document's main thread and permitted in a worker — including `responseType`,
/// which only the Window case rejects — and it suspends this thread until Swift
/// answers the request. So the host does not have to pre-drain stdin, which
/// matters more than it sounds: `ShellEngine` holds the foreground job's stdin
/// open for the life of the command, so waiting for EOF before starting would
/// deadlock every command that does not read stdin at all.
class Sync {
  constructor(base) { this.base = base; }

  /// Returns an ArrayBuffer, or null if the request failed. A failure is not
  /// fatal — the caller treats it as end-of-input, which degrades an
  /// unreachable host to "stdin was empty" rather than to a hung guest.
  get(path) {
    try {
      const request = new XMLHttpRequest();
      request.open('GET', this.base + path, false);
      request.responseType = 'arraybuffer';
      request.send();
      if (request.status !== 200) return null;
      return request.response;
    } catch (error) {
      return null;
    }
  }
}

class Stdin {
  constructor(sync) {
    this.sync = sync;
    this.buffer = new Uint8Array(0);
    this.offset = 0;
    this.eof = false;
  }

  read(max) {
    if (this.offset >= this.buffer.length) {
      if (this.eof) return new Uint8Array(0);
      const response = this.sync.get('/stdin');
      // Swift answers with zero bytes only at end of input; anything else
      // blocks on its side until there is something to say.
      if (!response || response.byteLength === 0) {
        this.eof = true;
        return new Uint8Array(0);
      }
      this.buffer = new Uint8Array(response);
      this.offset = 0;
    }
    const slice = this.buffer.subarray(this.offset, Math.min(this.offset + max, this.buffer.length));
    this.offset += slice.length;
    return slice;
  }
}

// MARK: - WASI

class WASI {
  constructor(options) {
    this.args = options.args;
    this.env = options.env;
    this.trees = options.trees;
    this.stdin = options.stdin;
    this.sync = options.sync;
    this.output = options.output;
    this.memory = null;
    this.exitCode = 0;

    // fd 0/1/2 are the standard streams; the preopens follow immediately,
    // because wasi-libc discovers them by walking upward from fd 3 and this
    // build of it treats the first as the working directory.
    this.fds = new Map();
    this.fds.set(0, { kind: 'stdin' });
    this.fds.set(1, { kind: 'stdout' });
    this.fds.set(2, { kind: 'stderr' });
    this.trees.forEach((tree, i) => {
      this.fds.set(3 + i, { kind: 'dir', tree, node: tree.root, preopen: tree.guestPath, offset: 0 });
    });
    this.nextFd = 3 + this.trees.length;
  }

  view() { return new DataView(this.memory.buffer); }
  bytes() { return new Uint8Array(this.memory.buffer); }

  fd(fd) {
    const entry = this.fds.get(fd);
    if (!entry) throw new Fail(E.BADF);
    return entry;
  }

  dir(fd) {
    const entry = this.fd(fd);
    if (entry.kind !== 'dir') throw new Fail(E.NOTDIR);
    return entry;
  }

  string(ptr, len) { return decoder.decode(this.bytes().subarray(ptr, ptr + len)); }

  /// Gathers an iovec array into one contiguous buffer.
  gather(ptr, count) {
    const view = this.view();
    let total = 0;
    for (let i = 0; i < count; i++) total += view.getUint32(ptr + i * 8 + 4, true);
    const out = new Uint8Array(total);
    let o = 0;
    for (let i = 0; i < count; i++) {
      const base = view.getUint32(ptr + i * 8, true);
      const len = view.getUint32(ptr + i * 8 + 4, true);
      out.set(this.bytes().subarray(base, base + len), o);
      o += len;
    }
    return out;
  }

  /// Scatters a buffer across an iovec array, returning how much landed.
  scatter(ptr, count, source) {
    const view = this.view();
    const target = this.bytes();
    let written = 0;
    for (let i = 0; i < count && written < source.length; i++) {
      const base = view.getUint32(ptr + i * 8, true);
      const len = Math.min(view.getUint32(ptr + i * 8 + 4, true), source.length - written);
      target.set(source.subarray(written, written + len), base);
      written += len;
    }
    return written;
  }

  writeFilestat(ptr, node) {
    const view = this.view();
    const nanos = BigInt(Math.round(node.mtime * 1e9));
    view.setBigUint64(ptr, 0n, true);
    view.setBigUint64(ptr + 8, BigInt(node.ino), true);
    view.setUint8(ptr + 16, node.kind === KIND.DIR ? FILETYPE.DIRECTORY
      : node.kind === KIND.LINK ? FILETYPE.SYMLINK : FILETYPE.REGULAR_FILE);
    view.setBigUint64(ptr + 24, 1n, true);
    view.setBigUint64(ptr + 32,
      BigInt(node.kind === KIND.LINK ? node.target.length : node.size), true);
    view.setBigUint64(ptr + 40, nanos, true);
    view.setBigUint64(ptr + 48, nanos, true);
    view.setBigUint64(ptr + 56, nanos, true);
  }

  guard(entry) {
    if (entry.tree && entry.tree.readOnly) throw new Fail(E.PERM);
  }

  /// Blocks this worker for `nanos`. Output is flushed first, so a program
  /// that prints and then sleeps does not look hung.
  sleep(nanos) {
    this.output.flush();
    this.sync.get(`/sleep?ns=${nanos.toString()}`);
  }

  imports() {
    const self = this;
    const view = () => self.view();

    const raw = {
      args_sizes_get(countPtr, sizePtr) {
        const v = view();
        v.setUint32(countPtr, self.args.length, true);
        v.setUint32(sizePtr, self.args.reduce((n, a) => n + encoder.encode(a).length + 1, 0), true);
        return E.SUCCESS;
      },

      args_get(argvPtr, bufPtr) {
        const v = view();
        const bytes = self.bytes();
        let p = bufPtr;
        self.args.forEach((arg, i) => {
          v.setUint32(argvPtr + i * 4, p, true);
          const encoded = encoder.encode(arg);
          bytes.set(encoded, p);
          bytes[p + encoded.length] = 0;
          p += encoded.length + 1;
        });
        return E.SUCCESS;
      },

      environ_sizes_get(countPtr, sizePtr) {
        const v = view();
        const pairs = Object.entries(self.env).map(([k, val]) => `${k}=${val}`);
        v.setUint32(countPtr, pairs.length, true);
        v.setUint32(sizePtr, pairs.reduce((n, s) => n + encoder.encode(s).length + 1, 0), true);
        return E.SUCCESS;
      },

      environ_get(envPtr, bufPtr) {
        const v = view();
        const bytes = self.bytes();
        let p = bufPtr;
        Object.entries(self.env).forEach(([k, val], i) => {
          v.setUint32(envPtr + i * 4, p, true);
          const encoded = encoder.encode(`${k}=${val}`);
          bytes.set(encoded, p);
          bytes[p + encoded.length] = 0;
          p += encoded.length + 1;
        });
        return E.SUCCESS;
      },

      clock_res_get(_id, ptr) {
        view().setBigUint64(ptr, 1000n, true);
        return E.SUCCESS;
      },

      clock_time_get(id, _precision, ptr) {
        // `performance.now()` is monotonic and sub-millisecond; `Date.now()` is
        // the wall clock a build system stamps files with.
        const nanos = id === 0
          ? BigInt(Math.round(Date.now() * 1e6))
          : BigInt(Math.round(performance.now() * 1e6));
        view().setBigUint64(ptr, nanos, true);
        return E.SUCCESS;
      },

      random_get(ptr, len) {
        // getRandomValues caps at 65536 bytes per call.
        const target = self.bytes().subarray(ptr, ptr + len);
        for (let o = 0; o < len; o += 65536) {
          crypto.getRandomValues(target.subarray(o, Math.min(o + 65536, len)));
        }
        return E.SUCCESS;
      },

      sched_yield() { return E.SUCCESS; },

      proc_exit(code) { throw new Exit(code); },

      proc_raise() { return E.NOSYS; },

      fd_write(fd, iovs, iovsLen, resultPtr) {
        const entry = self.fd(fd);
        const data = self.gather(iovs, iovsLen);
        if (entry.kind === 'stdout' || entry.kind === 'stderr') {
          self.output.write(data);
        } else if (entry.kind === 'file') {
          self.guard(entry);
          const offset = entry.append ? entry.node.size : entry.offset;
          writeInto(entry.node, offset, data);
          entry.offset = offset + data.length;
        } else {
          throw new Fail(E.BADF);
        }
        view().setUint32(resultPtr, data.length, true);
        return E.SUCCESS;
      },

      fd_pwrite(fd, iovs, iovsLen, offset, resultPtr) {
        const entry = self.fd(fd);
        if (entry.kind !== 'file') throw new Fail(E.SPIPE);
        self.guard(entry);
        const data = self.gather(iovs, iovsLen);
        writeInto(entry.node, Number(offset), data);
        view().setUint32(resultPtr, data.length, true);
        return E.SUCCESS;
      },

      fd_read(fd, iovs, iovsLen, resultPtr) {
        const entry = self.fd(fd);
        let read = 0;
        if (entry.kind === 'stdin') {
          const v = view();
          let capacity = 0;
          for (let i = 0; i < iovsLen; i++) capacity += v.getUint32(iovs + i * 8 + 4, true);
          read = self.scatter(iovs, iovsLen, self.stdin.read(capacity));
        } else if (entry.kind === 'file') {
          const slice = entry.node.data
            ? entry.node.data.subarray(entry.offset, entry.node.size)
            : new Uint8Array(0);
          read = self.scatter(iovs, iovsLen, slice);
          entry.offset += read;
        } else {
          throw new Fail(E.BADF);
        }
        view().setUint32(resultPtr, read, true);
        return E.SUCCESS;
      },

      fd_pread(fd, iovs, iovsLen, offset, resultPtr) {
        const entry = self.fd(fd);
        if (entry.kind !== 'file') throw new Fail(E.SPIPE);
        const start = Number(offset);
        const slice = entry.node.data
          ? entry.node.data.subarray(start, entry.node.size)
          : new Uint8Array(0);
        view().setUint32(resultPtr, self.scatter(iovs, iovsLen, slice), true);
        return E.SUCCESS;
      },

      fd_seek(fd, offset, whence, resultPtr) {
        const entry = self.fd(fd);
        if (entry.kind !== 'file') throw new Fail(E.SPIPE);
        const delta = Number(offset);
        const next = whence === 0 ? delta
          : whence === 1 ? entry.offset + delta
            : entry.node.size + delta;
        if (next < 0) throw new Fail(E.INVAL);
        entry.offset = next;
        view().setBigUint64(resultPtr, BigInt(next), true);
        return E.SUCCESS;
      },

      fd_tell(fd, resultPtr) {
        const entry = self.fd(fd);
        if (entry.kind !== 'file') throw new Fail(E.SPIPE);
        view().setBigUint64(resultPtr, BigInt(entry.offset), true);
        return E.SUCCESS;
      },

      fd_close(fd) {
        self.fd(fd);
        self.fds.delete(fd);
        return E.SUCCESS;
      },

      fd_renumber(from, to) {
        const entry = self.fd(from);
        self.fds.set(to, entry);
        self.fds.delete(from);
        return E.SUCCESS;
      },

      fd_fdstat_get(fd, ptr) {
        const entry = self.fd(fd);
        const v = view();
        const type = entry.kind === 'dir' ? FILETYPE.DIRECTORY
          : entry.kind === 'file' ? FILETYPE.REGULAR_FILE
            : FILETYPE.CHARACTER_DEVICE;
        v.setUint8(ptr, type);
        v.setUint16(ptr + 2, entry.append ? FDFLAGS.APPEND : 0, true);
        v.setBigUint64(ptr + 8, ALL_RIGHTS, true);
        v.setBigUint64(ptr + 16, ALL_RIGHTS, true);
        return E.SUCCESS;
      },

      fd_fdstat_set_flags(fd, flags) {
        const entry = self.fd(fd);
        entry.append = (flags & FDFLAGS.APPEND) !== 0;
        return E.SUCCESS;
      },

      fd_fdstat_set_rights() { return E.SUCCESS; },

      fd_prestat_get(fd, ptr) {
        const entry = self.fd(fd);
        if (!entry.preopen) throw new Fail(E.BADF);
        const v = view();
        v.setUint8(ptr, 0);
        v.setUint32(ptr + 4, encoder.encode(entry.preopen).length, true);
        return E.SUCCESS;
      },

      fd_prestat_dir_name(fd, ptr, len) {
        const entry = self.fd(fd);
        if (!entry.preopen) throw new Fail(E.BADF);
        const name = encoder.encode(entry.preopen);
        if (name.length > len) throw new Fail(E.NAMETOOLONG);
        self.bytes().set(name, ptr);
        return E.SUCCESS;
      },

      fd_filestat_get(fd, ptr) {
        const entry = self.fd(fd);
        if (!entry.node) throw new Fail(E.BADF);
        self.writeFilestat(ptr, entry.node);
        return E.SUCCESS;
      },

      fd_filestat_set_size(fd, size) {
        const entry = self.fd(fd);
        if (entry.kind !== 'file') throw new Fail(E.BADF);
        self.guard(entry);
        const next = Number(size);
        if (next > entry.node.size) writeInto(entry.node, entry.node.size, new Uint8Array(next - entry.node.size));
        else { entry.node.size = next; touch(entry.node); }
        return E.SUCCESS;
      },

      fd_filestat_set_times(fd, _atim, mtim, flags) {
        const entry = self.fd(fd);
        if (!entry.node) throw new Fail(E.BADF);
        self.guard(entry);
        if (flags & FSTFLAGS.MTIM) entry.node.mtime = Number(mtim) / 1e9;
        else if (flags & FSTFLAGS.MTIM_NOW) entry.node.mtime = Date.now() / 1000;
        entry.node.dirty = true;
        return E.SUCCESS;
      },

      fd_readdir(fd, bufPtr, bufLen, cookie, resultPtr) {
        const entry = self.dir(fd);
        const v = view();
        const bytes = self.bytes();

        // "." and ".." are not in the children map but a guest walking a
        // directory expects them, and some readdir loops key off `d_ino`.
        const listing = [
          { name: '.', node: entry.node },
          { name: '..', node: entry.node.parent || entry.node },
          ...[...entry.node.children.entries()].map(([name, node]) => ({ name, node })),
        ];

        let written = 0;
        let index = Number(cookie);
        while (index < listing.length && written < bufLen) {
          const item = listing[index];
          const name = encoder.encode(item.name);

          // Built whole, then copied in as far as it goes. A record that does
          // not fit must be *truncated* rather than skipped: the caller grows
          // its buffer when the reply fills it exactly, and stops when it does
          // not — so breaking out early here would look like the end of the
          // directory and silently lose every entry after a long filename.
          const record = new Uint8Array(24 + name.length);
          const header = new DataView(record.buffer);
          header.setBigUint64(0, BigInt(index + 1), true);
          header.setBigUint64(8, BigInt(item.node.ino), true);
          header.setUint32(16, name.length, true);
          header.setUint8(20,
            item.node.kind === KIND.DIR ? FILETYPE.DIRECTORY
              : item.node.kind === KIND.LINK ? FILETYPE.SYMLINK : FILETYPE.REGULAR_FILE);
          record.set(name, 24);

          const room = Math.min(record.length, bufLen - written);
          bytes.set(record.subarray(0, room), bufPtr + written);
          written += room;
          index++;
          if (room < record.length) break;
        }
        v.setUint32(resultPtr, written, true);
        return E.SUCCESS;
      },

      fd_sync() { return E.SUCCESS; },
      fd_datasync() { return E.SUCCESS; },
      fd_advise() { return E.SUCCESS; },
      fd_allocate() { return E.SUCCESS; },

      path_open(dirFd, lookupFlags, pathPtr, pathLen, oflags, _base, _inheriting, fdflags, resultPtr) {
        const entry = self.dir(dirFd);
        const path = self.string(pathPtr, pathLen);
        const follow = (lookupFlags & LOOKUP_SYMLINK_FOLLOW) !== 0;
        const found = entry.tree.resolve(entry.node, path, follow);

        let node = found.node;
        if (node && (oflags & OFLAGS.EXCL) && (oflags & OFLAGS.CREAT)) throw new Fail(E.EXIST);

        if (!node) {
          if (!(oflags & OFLAGS.CREAT)) throw new Fail(E.NOENT);
          if (entry.tree.readOnly) throw new Fail(E.PERM);
          node = makeNode(KIND.FILE, CREATE_FILE_MODE, Date.now() / 1000);
          node.data = new Uint8Array(0);
          node.dirty = true;
          link(found.parent, found.name, node);
        }

        if ((oflags & OFLAGS.DIRECTORY) && node.kind !== KIND.DIR) throw new Fail(E.NOTDIR);
        if (node.kind === KIND.DIR) {
          const fd = self.nextFd++;
          self.fds.set(fd, { kind: 'dir', tree: entry.tree, node, offset: 0 });
          view().setUint32(resultPtr, fd, true);
          return E.SUCCESS;
        }

        if (oflags & OFLAGS.TRUNC) {
          if (entry.tree.readOnly) throw new Fail(E.PERM);
          node.size = 0;
          node.data = new Uint8Array(0);
          node.shared = false;
          touch(node);
        }

        const fd = self.nextFd++;
        self.fds.set(fd, {
          kind: 'file',
          tree: entry.tree,
          node,
          offset: (fdflags & FDFLAGS.APPEND) ? node.size : 0,
          append: (fdflags & FDFLAGS.APPEND) !== 0,
        });
        view().setUint32(resultPtr, fd, true);
        return E.SUCCESS;
      },

      path_filestat_get(dirFd, lookupFlags, pathPtr, pathLen, ptr) {
        const entry = self.dir(dirFd);
        const found = entry.tree.resolve(
          entry.node, self.string(pathPtr, pathLen),
          (lookupFlags & LOOKUP_SYMLINK_FOLLOW) !== 0);
        if (!found.node) throw new Fail(E.NOENT);
        self.writeFilestat(ptr, found.node);
        return E.SUCCESS;
      },

      path_filestat_set_times(dirFd, _lookupFlags, pathPtr, pathLen, _atim, mtim, flags) {
        const entry = self.dir(dirFd);
        self.guard(entry);
        const found = entry.tree.resolve(entry.node, self.string(pathPtr, pathLen), true);
        if (!found.node) throw new Fail(E.NOENT);
        if (flags & FSTFLAGS.MTIM) found.node.mtime = Number(mtim) / 1e9;
        else if (flags & FSTFLAGS.MTIM_NOW) found.node.mtime = Date.now() / 1000;
        found.node.dirty = true;
        return E.SUCCESS;
      },

      path_create_directory(dirFd, pathPtr, pathLen) {
        const entry = self.dir(dirFd);
        self.guard(entry);
        const found = entry.tree.resolve(entry.node, self.string(pathPtr, pathLen), false);
        if (found.node) throw new Fail(E.EXIST);
        const node = makeNode(KIND.DIR, CREATE_DIR_MODE, Date.now() / 1000);
        node.dirty = true;
        link(found.parent, found.name, node);
        return E.SUCCESS;
      },

      path_remove_directory(dirFd, pathPtr, pathLen) {
        const entry = self.dir(dirFd);
        self.guard(entry);
        const found = entry.tree.resolve(entry.node, self.string(pathPtr, pathLen), false);
        if (!found.node) throw new Fail(E.NOENT);
        if (found.node.kind !== KIND.DIR) throw new Fail(E.NOTDIR);
        if (found.node.children.size) throw new Fail(E.NOTEMPTY);
        found.parent.children.delete(found.name);
        return E.SUCCESS;
      },

      path_unlink_file(dirFd, pathPtr, pathLen) {
        const entry = self.dir(dirFd);
        self.guard(entry);
        const found = entry.tree.resolve(entry.node, self.string(pathPtr, pathLen), false);
        if (!found.node) throw new Fail(E.NOENT);
        if (found.node.kind === KIND.DIR) throw new Fail(E.ISDIR);
        found.parent.children.delete(found.name);
        return E.SUCCESS;
      },

      path_rename(fromFd, fromPtr, fromLen, toFd, toPtr, toLen) {
        const from = self.dir(fromFd);
        const to = self.dir(toFd);
        self.guard(from);
        self.guard(to);
        // A rename across preopens is a copy the guest has to do itself, the
        // same as `EXDEV` across mount points on a real system.
        if (from.tree !== to.tree) throw new Fail(E.NOTSUP);
        const source = from.tree.resolve(from.node, self.string(fromPtr, fromLen), false);
        if (!source.node) throw new Fail(E.NOENT);
        const target = to.tree.resolve(to.node, self.string(toPtr, toLen), false);
        source.parent.children.delete(source.name);
        if (target.node) target.parent.children.delete(target.name);
        link(target.parent, target.name, source.node);
        touch(source.node);
        // Every descendant moved with it, so every descendant is a new path.
        const mark = (node) => {
          node.dirty = true;
          if (node.kind === KIND.DIR) for (const child of node.children.values()) mark(child);
        };
        mark(source.node);
        return E.SUCCESS;
      },

      path_symlink(targetPtr, targetLen, dirFd, pathPtr, pathLen) {
        const entry = self.dir(dirFd);
        self.guard(entry);
        const found = entry.tree.resolve(entry.node, self.string(pathPtr, pathLen), false);
        if (found.node) throw new Fail(E.EXIST);
        const node = makeNode(KIND.LINK, 0o777, Date.now() / 1000);
        node.target = self.string(targetPtr, targetLen);
        node.dirty = true;
        link(found.parent, found.name, node);
        return E.SUCCESS;
      },

      path_readlink(dirFd, pathPtr, pathLen, bufPtr, bufLen, resultPtr) {
        const entry = self.dir(dirFd);
        const found = entry.tree.resolve(entry.node, self.string(pathPtr, pathLen), false);
        if (!found.node) throw new Fail(E.NOENT);
        if (found.node.kind !== KIND.LINK) throw new Fail(E.INVAL);
        const target = encoder.encode(found.node.target);
        const length = Math.min(target.length, bufLen);
        self.bytes().set(target.subarray(0, length), bufPtr);
        view().setUint32(resultPtr, length, true);
        return E.SUCCESS;
      },

      path_link(_oldFd, _flags, oldPtr, oldLen, newFd, newPtr, newLen) {
        // A hard link would need the node to have more than one path, which the
        // sync-back has no way to express — the host side writes bytes per path.
        // Copying is what the guest observes either way, minus the shared inode.
        const to = self.dir(newFd);
        self.guard(to);
        const source = to.tree.resolve(to.node, self.string(oldPtr, oldLen), true);
        if (!source.node) throw new Fail(E.NOENT);
        const target = to.tree.resolve(to.node, self.string(newPtr, newLen), false);
        if (target.node) throw new Fail(E.EXIST);
        const copy = makeNode(source.node.kind, source.node.mode, Date.now() / 1000);
        copy.data = source.node.data;
        copy.size = source.node.size;
        copy.shared = true;
        copy.target = source.node.target;
        copy.dirty = true;
        link(target.parent, target.name, copy);
        return E.SUCCESS;
      },

      poll_oneoff(inPtr, outPtr, count, resultPtr) {
        const v = view();
        let emitted = 0;
        for (let i = 0; i < count; i++) {
          const sub = inPtr + i * 48;
          const userdata = v.getBigUint64(sub, true);
          const tag = v.getUint8(sub + 8);
          const out = outPtr + emitted * 32;
          v.setBigUint64(out, userdata, true);
          v.setUint16(out + 8, E.SUCCESS, true);
          v.setUint8(out + 10, tag);
          v.setBigUint64(out + 16, 0n, true);
          v.setUint16(out + 24, 0, true);

          if (tag === 0) {
            // A clock subscription is a sleep. Reporting it elapsed
            // immediately would be correct-ish but turns `sleep 1` into a spin
            // that pins a core, so it goes through the same synchronous
            // request stdin uses and Swift does the waiting.
            const flags = v.getUint16(sub + 40, true);
            let nanos = v.getBigUint64(sub + 24, true);
            // An absolute deadline is relative to the clock the guest named;
            // only the wall clock is meaningful to compare against here.
            if (flags & 1) {
              const now = BigInt(Math.round(Date.now() * 1e6));
              nanos = nanos > now ? nanos - now : 0n;
            }
            if (nanos > 0n) self.sleep(nanos);
            emitted++;
          } else {
            // Files are always ready; stdin is ready until it is exhausted,
            // and reporting it ready at EOF is what lets a reader see the zero
            // -length read that means end of file.
            v.setBigUint64(out + 16, 1n, true);
            emitted++;
          }
        }
        v.setUint32(resultPtr, emitted, true);
        return E.SUCCESS;
      },

      // Sockets never appear: nothing in the sandbox can hand a guest one.
      sock_accept() { return E.NOTSUP; },
      sock_recv() { return E.NOTSUP; },
      sock_send() { return E.NOTSUP; },
      sock_shutdown() { return E.NOTSUP; },
    };

    // Every call but `proc_exit` reports failure by returning an errno, so a
    // thrown `Fail` is turned back into one rather than trapping the guest —
    // the same completion the interpreter backend does in `WASIErrno`.
    const wrapped = {};
    for (const [name, fn] of Object.entries(raw)) {
      wrapped[name] = (...args) => {
        try {
          return fn(...args);
        } catch (error) {
          if (error instanceof Fail) return error.errno;
          if (error instanceof Exit) throw error;
          if (error instanceof RangeError) return E.FAULT;
          throw error;
        }
      };
    }
    return wrapped;
  }
}

// MARK: - Entry point

async function run(spec) {
  const output = new Output();
  const sync = new Sync(spec.syncURL);
  const trees = spec.preopens.map((p, i) => {
    const tree = new Tree(i, p.guestPath, p.readOnly);
    tree.load(spec.snapshots[i]);
    return tree;
  });

  const wasi = new WASI({
    args: [spec.argv0, ...spec.arguments],
    env: spec.environment,
    trees,
    stdin: new Stdin(sync),
    sync,
    output,
  });

  const imports = wasi.imports();
  const instance = await WebAssembly.instantiate(spec.module, {
    wasi_snapshot_preview1: imports,
    // Some toolchains emit the older module name. Same table either way.
    wasi_unstable: imports,
  });
  wasi.memory = instance.exports.memory;

  const guestBegan = performance.now();
  let status = 0;
  try {
    if (typeof instance.exports._start !== 'function') {
      throw new Error('not an executable module (no _start export)');
    }
    instance.exports._start();
  } catch (error) {
    if (error instanceof Exit) {
      status = error.code;
    } else {
      output.flush();
      throw error;
    }
  }
  output.flush();
  const guest = Math.round(performance.now() - guestBegan);

  // The diff, computed once at the end. Nothing is written back mid-run: the
  // host has no way to observe an in-flight guest anyway, and a program that
  // traps should not leave half its output on disk.
  const diffBegan = performance.now();
  const changes = [];
  const deletions = [];
  for (const tree of trees) tree.collect(changes, deletions);
  const diff = pack(changes, deletions);

  return { status, diff, guest, diffMs: Math.round(performance.now() - diffBegan) };
}

/// Builds the `WSHW` blob. Mirrors `WasmWriteback.parse`.
function pack(changes, deletions) {
  // magic, version, and both counts — the trailing deletion count is as much
  // a part of the header as the leading change count.
  let total = 16;
  const encoded = changes.map((change) => {
    const path = encoder.encode(change.path);
    const node = change.node;
    const body = node.kind === KIND.LINK ? encoder.encode(node.target)
      : node.kind === KIND.FILE ? node.data.subarray(0, node.size)
        : new Uint8Array(0);
    total += 25 + path.length + body.length;
    return { change, path, body };
  });
  const encodedDeletions = deletions.map((deletion) => {
    const path = encoder.encode(deletion.path);
    total += 8 + path.length;
    return { deletion, path };
  });

  const buffer = new ArrayBuffer(total);
  const v = new DataView(buffer);
  const bytes = new Uint8Array(buffer);
  bytes.set(encoder.encode('WSHW'), 0);
  v.setUint32(4, 1, true);
  v.setUint32(8, encoded.length, true);

  let o = 12;
  for (const { change, path, body } of encoded) {
    v.setUint32(o, change.preopen, true); o += 4;
    v.setUint8(o, change.node.kind); o += 1;
    v.setUint32(o, path.length, true); o += 4;
    v.setUint32(o, body.length, true); o += 4;
    v.setUint32(o, change.node.mode, true); o += 4;
    v.setFloat64(o, change.node.mtime, true); o += 8;
    bytes.set(path, o); o += path.length;
    bytes.set(body, o); o += body.length;
  }
  v.setUint32(o, encodedDeletions.length, true); o += 4;
  for (const { deletion, path } of encodedDeletions) {
    v.setUint32(o, deletion.preopen, true); o += 4;
    v.setUint32(o, path.length, true); o += 4;
    bytes.set(path, o); o += path.length;
  }
  return buffer;
}

/// Safari's `error.stack` is frames only — it does not lead with the message
/// the way V8's does. Reporting the stack alone loses the one line that says
/// what actually went wrong, which turns every guest failure into a puzzle.
function describe(error) {
  if (error instanceof Error) {
    return `${error.name}: ${error.message}\n${error.stack || '<no stack>'}`;
  }
  return String(error);
}

self.onmessage = async (event) => {
  try {
    const { status, diff, guest, diffMs } = await run(event.data);
    postMessage({ type: 'exit', status, diff, guest, diffMs }, [diff]);
  } catch (error) {
    postMessage({ type: 'failed', message: describe(error) });
  }
};
