import Foundation

struct BridgeInstallation {
    let setup: String
    let uploads: [String]
    let finish: String
    let cleanup: String

    init(resources: [String: Data]) {
        let staging = ".install-" + UUID().uuidString
        let directory = "directory=pathlib.Path.home()/'.local/share/codex-ipad'\nstaging=directory/\(String(reflecting: staging))\n"
        func command(_ script: String) -> String {
            "python3 -c " + RemoteShell.quote("import base64,os,pathlib,shutil\nos.umask(0o077)\n" + directory + script)
        }
        setup = command("""
        directory.mkdir(parents=True,exist_ok=True,mode=0o700)
        if directory.is_symlink() or directory.stat().st_uid != os.getuid(): raise RuntimeError('Invalid bridge directory')
        directory.chmod(0o700)
        staging.mkdir(mode=0o700)
        """)
        var chunks: [String] = []
        for name in resources.keys.sorted() {
            let data = resources[name]!
            // Keep every SSH command well below Linux's 128 KiB per-argument limit.
            for offset in stride(from: 0, to: data.count, by: 24 * 1024) {
                let encoded = data.subdata(in: offset..<min(offset + 24 * 1024, data.count)).base64EncodedString()
                chunks.append(command("""
                with (staging/\(String(reflecting: name))).open('\(offset == 0 ? "xb" : "ab")') as file:
                    file.write(base64.b64decode('\(encoded)',validate=True))
                """))
            }
        }
        uploads = chunks
        let names = resources.keys.sorted().map { String(reflecting: $0) }.joined(separator: ",")
        finish = command("""
        names=[\(names)]
        for name in names:
            compile((staging/name).read_bytes(),name,'exec')
            if (directory/name).is_symlink(): raise RuntimeError('Invalid bridge file')
        for name in names:
            os.replace(staging/name,directory/name)
        staging.rmdir()
        """)
        cleanup = command("shutil.rmtree(staging,ignore_errors=True)")
    }
}
