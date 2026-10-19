# 本机固定签名（避免每次更新都输入钥匙串密码）

## 为什么会反复弹窗

- 登录凭据保存在钥匙串里。macOS 按「条目 + App 签名」授权访问。
- 默认构建使用临时签名（ad-hoc）：每次构建签名都会变，系统会把新版本当成另一个 App，于是再次询问密码。
- 2026-10-18 之前，凭据分存在两个条目里（Cookie 与令牌），所以每次要授权两次。现已合并为一个条目 `io.github.pidean.manping.session.v2`：首次启动时读取一次旧条目完成迁移，之后每个新版本只需授权一次。

## 一次设置，之后不再询问

只要用固定证书签名，钥匙串认的就是「证书 + App 标识」。点一次「始终允许」后，之后的所有构建都不会再询问。以下两种方式任选其一，都需要使用者操作：

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

钥匙串只核对这个要求，所以从官方发布包升级到下一个官方版本时，不会再请求授权。

- 证书和私钥放在发布者本机的 `~/Library/Application Support/Manping Signing/`：一个单独的钥匙串文件加上它的密码文件。这个钥匙串不在系统的钥匙串搜索列表里，也没有设为系统信任，`scripts/bundle.py` 签名时会直接指定它。
- 这个目录不在仓库里。丢了就无法再签出「同一个 App」，用户升级时会重新弹一次授权。请把整个目录备份到安全的地方。
- 自己从源码构建时没有这张证书，会按下文的顺序选择签名，钥匙串会把你的构建当成另一个 App。

## 说明

- `scripts/bundle.py` 按以下顺序选择签名：
  1. 环境变量 `MANPING_SIGN_IDENTITY`，可以配合 `MANPING_SIGN_KEYCHAIN` 指定钥匙串文件；
  2. 上面的正式发布签名钥匙串；
  3. 名为 `Manping Local Signing` 的证书；
  4. 都没有时使用临时签名。
- `scripts/build_debug_app.py` 使用其中的 1、3、4。调试版有独立的设置和钥匙串域。
- 首次用证书签名时，`codesign` 可能会请求使用该证书的私钥。请选择「始终允许」。
- 换成固定签名后的第一次启动仍会请求一次授权，因为签名从临时签名换成了证书。之后不会再请求。
