# 分发与发版

## 当前渠道

macOS 店外分发。Developer ID 签名，Apple 公证，DMG 拖进 Applications。没有使用 App Store。

## 机器上已有的东西

签名身份在登录钥匙串，不要写死名字，用命令取：

```bash
IDENTITY="$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -n 1)"
echo "$IDENTITY"
```

公证凭据存在本机的 `~/.config/quik/notary.env`（目录 700，文件 600），不在钥匙串里。钥匙串会被系统整体重建，2026-11-15 23:07 发生过一次，`login.keychain-db` 的创建时间即证据，重建后 profile 就没了，发版因此卡了一小时。

文件内容：

```bash
QUIK_NOTARY_APPLE_ID=<Apple ID 邮箱>
QUIK_NOTARY_TEAM_ID=<Team ID，从证书的 OU 字段读>
QUIK_NOTARY_PASSWORD=<App 专用密码>
```

`package.sh` 启动就读取这个文件，缺失、不完整或凭据被拒都在构建前退出，不消耗构建时间。密码以字面值通过 `--password` 传给 `notarytool`：它没有 `@env:` 这种引用方式（那是 `altool` 的功能），传 `@env:NAME` 会把字面字符串当密码，每次都是 401。代价是密码在公证请求期间会出现在本机的 `ps` 里。目录在仓库之外，`.gitignore` 另外挡了 `.env` 与 `*.env` 两道。

仍然可用的旧方式：`QUIK_NOTARY_PROFILE=quik-notary` 走钥匙串 profile。两条路都保留，文件优先。

## 发版

1. 改版本号，`project.yml` 与 `Sources/App/Info.plist` 两处都要改。
2. 打包并公证：

```bash
QUIK_SIGN_IDENTITY="$IDENTITY" scripts/package.sh
```

凭据从 `~/.config/quik/notary.env` 自动读取，不需要在命令行上传。

3. 验证产物：

```bash
scripts/verify-package.sh
```

4. 提交并发布：

```bash
git tag -a vX.Y.Z -m "Quik X.Y.Z"
git push origin main vX.Y.Z
gh release create vX.Y.Z \
  build/package/Quik-X.Y.Z.dmg \
  build/package/Quik-X.Y.Z.zip \
  build/package/SHA256SUMS \
  --title "Quik X.Y.Z" --notes-file /tmp/quik-release-notes.md
```

不要用 `--tags` 推送：它会把本地所有残杂 tag 一起推上去（2026-11-15 发布 0.2.2 时，本地的旧 `v0.2.0` 与编辑器插件的 `local-history-*` 都被带了上去，事后逐个补删）。删 tag 时本地远端都要删，只删远端的话下次推送又会回来。公证 Accepted 但 staple 网络失败时，脚本会在 SHA256SUMS 之前退出；staple 可单独重试 `xcrun stapler staple <dmg>`，但校验和必须重新生成或重跑整个脚本，发布前 `cat build/package/SHA256SUMS` 确认版本号。

5. 回下载核对：

```bash
curl -sL -o /tmp/quik.dmg https://github.com/lesliechowsh/quik/releases/download/vX.Y.Z/Quik-X.Y.Z.dmg
shasum -a 256 /tmp/quik.dmg
grep 'Quik-X.Y.Z.dmg' build/package/SHA256SUMS
```

公开 Release 之前先和人确认版本号与发布说明。

## 凭据重建

证书：钥匙串访问的“证书助理”生成 CSR，在 developer.apple.com 的 Certificates 里创建 Developer ID Application，上传 CSR，下载 `.cer` 后双击导入。

公证 profile：

```bash
xcrun notarytool store-credentials quik-notary \
  --apple-id <AppleID> --team-id <TeamID>
```

`<TeamID>` 从证书的 `OU` 字段读：

```bash
security find-certificate -c "Developer ID Application" -p \
  | openssl x509 -noout -subject
```

## 新 agent 能自己做到哪一步

能自己发现并完成：证书身份、打包、签名、公证、staple、产物校验、生成发布资产、如果 `gh` 已登录则创建 Release。

必须问人：Apple ID 密码与双重认证、App 专用密码、App Store Connect 的协议与税务信息、商品页文案与截图、隐私政策、定价、审核提交。这些不进仓库，也不该进对话。

## App Store 的边界

Quik 不能直接上 Mac App Store。它用 `libproc`、IOKit 和 `sample` 读全系统进程，App Sandbox 会挡住这些能力。要上架需要重写核心采集并接受审核。

普通应用或游戏如果准备上架，从第一天开 App Sandbox，使用 Apple Distribution 证书，在 App Store Connect 建应用记录。iPhone 和 iPad 只能走 App Store，测试用 TestFlight。

## 身份规则

只用个人团队。公司团队永久排除，签名、公证、发布都不要用它。仓库、Release 和文档里不写公司名称。
