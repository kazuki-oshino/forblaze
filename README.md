# forblaze

macOS向けの日本語音声入力アプリ。
ローカルで動作し完全無料。
キーを押して話すと、入力中のアプリに文字が入る。音声認識にはAppleのSpeechAnalyzerを使う。
個人辞書や、声に合わせて画面の縁が燃える「フォルブレイズモード」もある。

## 動作環境

macOS 26以降のApple Silicon Macが必要。
ビルドにはXcode、Python 3、[just](https://github.com/casey/just)を使う。Xcode 26.3でビルドを確認している。
インストールには自分のApple Development署名証明書を用意する。

## インストール

ソースからビルドする。

```sh
git clone https://github.com/kazuki-oshino/forblaze.git
cd forblaze
just build
```

署名証明書の名前またはSHA-1を指定して署名し、`/Applications/forblaze.app`へインストールする。

```sh
FORBLAZE_SIGNING_IDENTITY='自分のApple Development署名の名前またはSHA-1' just signing-check
just install
just run
```

更新するときはアプリを終了し、`git pull --ff-only`の後にビルドから同じ手順を繰り返す。

## 使い方

1. メニューバーのforblazeから設定を開き、「アクセス権」で入力監視・アクセシビリティ・マイク・音声認識を許可する。日本語モデルが未導入ならダウンロードを待つ。
2. 入力したい欄をクリックし、F8を押して話す。もう一度F8を押すと終了する。
3. キーは設定の「一般」で変更できる。よく使う単語の表記は「個人辞書」に登録する。

手入力や入力先の切り替えでも音声入力は終了する。パスワード欄など、入力できない欄もある。

## 句読点補正

Jevによる句読点補正は任意で、初期状態はオフ。
使う場合はリポジトリ直下の`.env`に自分のAPIキーを設定し、アプリを再起動して「音声入力」→「句読点を補正する」をオンにする。

```dotenv
TYPESAFE_API_KEY=自分のAPIキー
```

オンの間は句読点の前後の文章をTypeSafeのJev APIへ送信する。音声は送信しない。
送信した文章とAPIの使用量は、このMacの`~/Library/Logs/forblaze/jev/`に保存される。

## 開発

`just check`でテストと構成を確認し、`just build`でビルドする。
ほかのコマンドは`just --list`で確認できる。

## ライセンス

[MIT](LICENSE)
