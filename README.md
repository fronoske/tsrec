# tsrec
TV program recording tool using mirakurun/mirakc

### これは何？
mirakurun もしくは mirakc を用いた全録コマンドです。
１つのコマンド実行で１局（１サービス）を全録します。

### 動機
「全録」といっても要するにただTSストリームを保存して番組ごとに切り分けるだけなので、そのためにわざわざ EPGStation や EDCB を立ち上げるのも重いなあと思っていました。

tsdumpは手軽で多機能な全録ソフトウェアですが、私の環境では番組情報を取得できないことが頻繁に発生したので使用を断念しました。
recpt1とスクリプトの組み合わせでもなんとかできそうでしたが、mirakurun/mirakc を使えば Web APIで容易に番組情報やストリームを取得できたので、それを利用することとしました。

### 動作環境
以下の環境が必要です。
- mirakurun もしくは mirakc サーバーが稼働していること
- Ruby がインストールされていること
- curl コマンドが使用できること

### 動作確認環境
以下の環境で動作確認しています。
- Ubuntu 20.04
- mirakc with recpt1 --b25
- Ruby 2.7.2
- curl 7.68.0

### 使用方法
本リポジトリを clone して tsrec.rb を実行するだけです。
１つのコマンドで１サービスを全録するので、複数のサービスを全録する場合はコマンドを複数回実行してください。

```
（例）
tsrec.rb -s 1048 -l log-TBS.txt -o /mnt/d/ZR/TBS &
tsrec.rb -s  101 -l log-BS1.txt -o /mnt/d/ZR/BS1 &
```

### コマンドラインオプション
```
Usage: tsrec [options]
    -s serviceId                     service ID
    -m marginSec                     margin sec to rec (default: 5)
    -o outDir                        Output directory
    -f outfileFormat                 out file format (default: %Y%m%d_%H%M %%T.ts)
    -p command                       pipe command
    -d                               debug mode
    -l logfile                       output log (default: stderr)
    -u host:port                     mirakc host:port (default: localhost:40772)
```
| オプション  | 説明 | デフォルト |
|:--|:--:|:--:|
| -s ServiceID | 全録する対象のサービスID | なし（必須）|
| -m marginSec | 番組開始の何秒前から録画するか | `5` |
| -o outDir    | 出力先ディレクトリ | なし（ファイル保存をする場合は必須）|
| -f outputFormat | TSファイル名の書式（後述） | `%Y%m%d_%H%M %%T.ts` |
| -p command   | 標準入力を得て実行するコマンド（後述） | なし |
| -d           | 詳細ログ | `false` |
| -l logfile   | ログファイル | `stderr` |
| -u host:port | mirakurun/mirakcサーバーのホスト名とポート番号 | `localhost:40772` |

### TSファイル名の書式
原則として strftime(3) に準じます。
加えて、以下の指定文字を使用できます。
- %%T：番組のタイトル
- %%S：サービス名（未実装）
- %%s: サービスID（未実装）

### パイプコマンド

### 環境変数


### 動作原理
1. コマンドを実行すると、mirakucunサーバーからチャンネル情報を取得してスクリプト内部に保持します。
そのほか、オプション処理などを行います。
2. mirakurunサーバーから番組情報を取得します
3. その中から、指定されたサービスの次の番組情報を取得します
4. 次の番組の開始時刻の marginSec 秒分前まで待機（sleep）します
5. curlコマンドを呼び出し、番組をTSファイルとして保存します。
6. curlコマンドの終了を待たずに次に進みます。
7. 番組の終了時刻の 1 分前まで待機します。
8. 2に戻ります。
終了するまでこれを繰り返します。

### TODO
- 番組情報をJSONで保存する
- tsrecプロセスをコントロールするためのコマンドを用意する
