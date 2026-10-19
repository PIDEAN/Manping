# 本机固定签名

## 签名还影响什么

- 从 0.1.3 起，登录凭据、代理密码和 AI 密钥不再放在钥匙串里，而是加密保存在 `~/Library/Application Support/Manping/Secrets/`（实现见 `LocalSecretVault.swift`），读取时不看签名，所以升级和重新构建都不会再弹钥匙串窗口。
- 改用本地加密存储的原因：钥匙串对没有 Apple 团队 ID 的自签名 App 实际上是按每一次构建授权的。即使签名要求不变，每个新版本也要再输一次登录密码（启动时一次，第一次使用 AI 时又一次），之前的「固定证书就不再询问」在实际使用中并不成立。
- 0.1.2 及更早版本的数据只在第一次需要时从钥匙串读一次（可能弹最后一次窗口），之后删除旧条目。删除时不会为了清理再弹窗；需要授权才能删掉的条目会留在钥匙串里，可以在「钥匙串访问」中搜索 `io.github.pidean.manping` 手动删除，满屏不会再读取它们。
- 签名仍然影响防火墙软件（如 LuLu）的放行规则和系统的隐私授权：临时签名的每次构建都会被当成新 App。

## 一次设置固定签名

用固定证书签名后，按签名放行的软件认的是「证书 + App 标识」，之后的构建不必重新放行。以下两种方式任选其一，都需要使用者操作：

1. **Apple Development 证书（推荐）**
   - 在 Xcode →「设置」→「Accounts」中选择你的 Apple ID 与团队，点「Manage Certificates…」，再点「+」→「Apple Development」。
   - 构建前设置环境变量：

     ```bash
     export MANPING_SIGN_IDENTITY="Apple Development: 你的名字 (团队ID)"
     ```

   - 现有的 iPhone Distribution 证书不能用于 Mac App。
2. **自签名证书**
   - 打开「钥匙串访问」，依次选择「证书助理」→「创建证书…」。
   - 名称填 `Manping Local Signing`，身份类型选「自签名根证书」，证书类型选「代码签名」。
   - 创建后，构建脚本会自动识别并使用它，不需要设置环境变量。

## 正式发布签名

`dist/release` 下的发布包用固定的自签名证书「Manping Release Signing」签名，保证每个版本的签名要求都一样：

```
identifier "io.github.pidean.manping" and certificate root = H"09563c850e9f0497c046106ebba51b39cb288c89"
```

按签名放行的软件只核对这个要求，所以官方版本之间升级时规则保持有效。

- 证书和私钥放在发布者本机的 `~/Library/Application Support/Manping Signing/`：一个单独的钥匙串文件加上它的密码文件。这个钥匙串不在系统的钥匙串搜索列表里，也没有设为系统信任，`scripts/bundle.py` 签名时会直接指定它。
- 这个目录不在仓库里。丢了就无法再签出「同一个 App」，用户升级后需要重新放行防火墙等规则。请把整个目录备份到安全的地方。
- 自己从源码构建时没有这张证书，会按下文的顺序选择签名，防火墙等会把你的构建当成另一个 App。

## 说明

- `scripts/bundle.py` 按以下顺序选择签名：
  1. 环境变量 `MANPING_SIGN_IDENTITY`，可以配合 `MANPING_SIGN_KEYCHAIN` 指定钥匙串文件；
  2. 上面的正式发布签名钥匙串；
  3. 名为 `Manping Local Signing` 的证书；
  4. 都没有时使用临时签名。
- `scripts/build_debug_app.py` 使用其中的 1、3、4。调试版有独立的设置和凭据目录（`Secrets-debug`），也不会读取钥匙串里的旧数据。
- 首次用证书签名时，`codesign` 可能会请求使用该证书的私钥。请选择「始终允许」。
- 换成固定签名后的第一次启动，防火墙等仍会请求一次放行，因为签名从临时签名换成了证书。
