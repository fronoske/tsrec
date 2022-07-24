> **Warning**
>
> 現在、本スクリプトの動作確認ができないためこの README の説明は間違ってるかもしれません。ご了承ください。

# tsrec
TV program recording tool using mirakurun/mirakc

### これは何？
mirakurun もしくは mirakc（以下「mirakurun」と総称します）を用いた全録コマンドです。

### 動機
「全録」といっても要するにただTSストリームを保存して番組ごとに切り分けるだけなので、そのためにわざわざ EPGStation や EDCB を立ち上げるのも重いなあと思っていました。

tsdump は手軽で多機能な全録ソフトウェアですが、私の環境では番組情報を取得できないことが頻繁に発生したので使用を断念しました。
recpt1 とスクリプトの組み合わせでもなんとかできそうでしたが、mirakurun を使えば Web APIで容易に番組情報やストリームを取得できたので、それを利用することとしました。

### 動作環境
以下の環境が必要です。
- mirakurun サーバーが稼働していること
- Ruby がインストールされていること
- curl コマンドが使用できること
- OS が fork() システムコールを使用可能なこと

### 動作確認環境
以下の環境で動作確認しています。
- Ubuntu 20.04
- mirakc with recpt1 --b25
- Ruby 2.7.2
- curl 7.68.0

### 使用方法
```
# 本リポジトリをクローンする
git clone https://github.com/fronoske/tsrec/
# 設定ファイルを記述する
cd tsrec
vim tsrec.yml
# tsrecを実行する
bundle install
bundle exec tsrec.rb ...
```

### コマンドライン
```
bundle exec tsrec.rb [subcommand] [options...]
```

### 設定ファイル
設定ファイルは YAML 形式です。
基本的に、全録したいチャンネルごとにセクションを記述します。
common セクションを記述することで各セクション内で指定しない場合のデフォルトの設定を指定することができます。
以下はサンプルです。

```
common:
  marginSec: 5
  outDir: "/var/tmp/tsrec"
  outFileFormat: "%Y%m%d_%H%M %%T.ts"
  noTS: false
  outJson: false
  outText: true
  pipeCommand: null
  followingCommand: null
  ignoreList: []
  logLevel: "info"
  server: "localhost:40772"
BS1:
  serviceId: 101
  outDir: "/pub/recorded/BS1"
  logFile: "/pub/recorded/tsrec-BS1.log"
  logLevel: "debug"
  ignoreList: ["天気"]
NHK-G:
  serviceId: 1024
  outDir: "/pub/recorded/NHK-G"
  logFile: "/pub/recorded/tsrec-NHK-G.log"
  logLevel: "error"
```

### サブコマンド

#### start
指定したセクションの全録を開始します。セクション名が必須です。

#### stop
指定したセクションの全録を停止します。セクション名が必須です。
セクション名を指定しなかった場合は現在実行中のセクションを一覧表示します。

#### status, ps
現在実行中のセクションを一覧表示します。

#### list
mirakurun が受信可能なチャンネルを一覧表示します。
放送種別（GR, BS, CS）を指定した場合はその放送種別のチャンネルのみを表示します。


```
（例）
bundle exec tsrec.rb start TBS
bundle exec tsrec.rb start BS1
bundle exec tsrec.rb stop TBS
```


### 使用上の注意
- 本ツールでは暗号化の解除は行いません。mirakurun から受信するストリームがすでに復号化されていることが前提です。
- 本ツールの置かれたディレクトリに各種の一時ファイルを格納・更新します。書き込み権限に注意してください。

### コマンドラインオプション
-c 以外はすべて設定ファイルで指定可能ですが、コマンドラインオプションによってそれを上書きすることができます。

```
-c config.yml       configuration file (default: tsrec.yml)
-s serviceId        service ID
-m marginSec        margin sec to rec [0-15] (default: 5)
-o outDir           output directory (default: $TEMP/tsrec")
-f outfileFormat    TS file format (default: "%Y%m%d_%H%M %%T.ts")
-n                  not output TS file
-j                  output program information JSON file
-t                  output program information TEXT file
-p command          pipe command (experimental)
-a command          command following each rec end
-x ignoreList       skip rec if program tilte matches the regex (separeted by comma)
-l logfile          output log (default: stdout)
-v loglevel         loglevel [fatal(0)|error(1)|warn(2)|info(3)|debug(4)|max(5)] (default:info)
-u host:port        mirakurun server host:port (default: localhost:40772)

```
| オプション  | 説明 | デフォルト値 |
|:--|:--|:--:|
| -c config.yml | 設定ファイル | tsrec.yml（必須）|
| -s ServiceId | 全録する対象のサービスID | - |
| -m marginSec | 番組開始の何秒前から録画するか | `5` |
| -o outDir    | 出力先ディレクトリ | $TEMP/tsrec |
| -f outputFormat | TSファイル名の書式（後述） | `%Y%m%d_%H%M %%T.ts` |
| -n           | TSファイルを出力しない。-p オプションが必須となる | - |
| -j           | 番組情報ファイルを JSON 形式で出力する | - |
| -t           | 番組情報ファイルをテキスト形式で出力する | - |
| -p command   | 標準入力を得て実行するコマンド（後述） | - |
| -a command   | 番組の録画が終了した後に実行するコマンド（後述） | - |
| -x ignoreList | 無視する番組のタイトルを正規表現で記述したもの。コンマ区切りで複数指定可（シェルによる展開に注意） | - |
| -l logfile   | ログファイル | `stderr` |
| -v loglevel  | ログの詳細レベル | `info` |
| -u host:port | mirakurun サーバーのホスト名とポート番号 | `localhost:40772` |


### TSファイル名の書式
原則として strftime(3) に準じます。加えて、以下の指定文字を使用できます。
- %%T：番組のタイトル
- %%S：サービス名（未実装）
- %%s: サービスID（未実装）

### 無視する番組タイトル
デフォルトで正規表現 `^放送(休止|終了)$`, `^休止$` に合致する番組を無視します（これを無効にはできません）。\
ignoreList によって追加することが可能です。


### pipeコマンド（実験的）
-p オプションでストリームを標準入力として受け付けるコマンドを指定することができます。
- -p オプションを指定すると、ストリームを標準出力に流します。
- このとき、-o オプションがない場合はファイルへの保存は行わず標準出力のみになり、-o オプションがある場合はファイルに保存しつつストリームを標準出力に流します。

コマンドの実行時には後述の環境変数を使用できます。（※シェルによる展開に注意してください。）
```
（例）
tsrec.rb -s 1048 -p 'ffmpeg -i - "${TSREC_OUT_PATH_BASE}.mp4"' # TSファイルを保存せずffmpegでMP4エンコードする
tsrec.rb -s 1048 -o /pub/recorded/TBS -p 'ffmpeg -i - "${TSREC_OUT_PATH_BASE}.mp4"' # TSファイルを保存しつつMP4エンコードする
```

### postコマンド
-a オプションで各番組の録画完了後に実行するコマンドを指定することができます。\
コマンドの実行時には後述の環境変数を使用できます。（※シェルによる展開に注意してください。）
```
（例）
tsrec.rb -s 1048 -o /pub/recorded/TBS -a 'tsselect "${TSREC_OUT_PATH}" >> TBS-drop.log' # 録画完了後にtsselectでドロップチェックする
```

### 環境変数
| 環境変数名               | 説明 |
|:--|:--|
| TSREC_TITLE             | 番組のタイトル |
| TSREC_START_AT_Y        | 番組開始時刻の年 |
| TSREC_START_AT_M        | 番組開始時刻の月 |
| TSREC_START_AT_M2       | 番組開始時刻の月（2桁） |
| TSREC_START_AT_D        | 番組開始時刻の日 |
| TSREC_START_AT_D2       | 番組開始時刻の日（2桁） |
| TSREC_START_AT_W        | 番組開始時刻の曜日 0(Sun) - 6(Sat) |
| TSREC_START_AT_H        | 番組開始時刻の時間 |
| TSREC_START_AT_H2       | 番組開始時刻の時間（2桁） |
| TSREC_START_AT_MIN      | 番組開始時刻の分 |
| TSREC_START_AT_MIN2     | 番組開始時刻の分（2桁） |
| TSREC_END_AT_Y          | 番組終了時刻の年 |
| TSREC_END_AT_M          | 番組終了時刻の月 |
| TSREC_END_AT_M2         | 番組終了時刻の月（2桁） |
| TSREC_END_AT_D          | 番組終了時刻の日 |
| TSREC_END_AT_D2         | 番組終了時刻の日（2桁） |
| TSREC_END_AT_W          | 番組終了時刻の曜日 0(Sun) - 6(Sat) |
| TSREC_END_AT_H          | 番組終了時刻の時間 |
| TSREC_END_AT_H2         | 番組終了時刻の時間（2桁） |
| TSREC_END_AT_MIN        | 番組終了時刻の分 |
| TSREC_END_AT_MIN2       | 番組終了時刻の分（2桁） |
| TSREC_DURATION_SEC      | 番組の長さ（秒） |
| TSREC_PROGRAM_ID        | mirakurun の Program ID |
| TSREC_EVENT_ID          | イベントID |
| TSREC_SERVICE_ID        | サービスID |
| TSREC_SERVICE_NAME      | サービス名 |
| TSREC_SERVICE_CHANNEL   | 物理チャンネル番号 |
| TSREC_SERVICE_TYPE      | サービスの種類（GR, BS, CS） |
| TSREC_NETWORK_ID        | ネットワークID |
| TSREC_DESC              | 番組の説明 |
| TSREC_EXTENDED          | 番組の詳細説明（改行を'\n'に変換） |
| TSREC_OUT_PATH          | 保存先TSファイルのフルパス |
| TSREC_OUT_PATH_BASE     | 保存先TSファイルのフルパスから拡張子を除去したもの |
| TSREC_OUT_DIR           | 保存先ディレクトリ |
| TSREC_OUT_BASE          | 保存先TSファイルのファイル名から拡張子を除去したもの |
| TSREC_OUT_EXT           | 保存先TSファイルの拡張子 |
| TSREC_VIDEO_STREAM      | 映像の Stream Content（数値） |
| TSREC_VIDEO_COMPONENT   | 映像の Component Type（数値） |
| TSREC_VIDEO_COMPONENT_S | 映像の Component Type（日本語） |
| TSREC_VIDEO_TYPE        | 映像のコーデック |
| TSREC_AUDIO_COMPONENT   | 音声の Component Type（数値） |
| TSREC_AUDIO_COMPONENT_S | 音声の Component Type（日本語） |
| TSREC_AUDIO_RATE        | 音声のビットレート |
| TSREC_GENRE1            | ジャンル1（メイン） |
| TSREC_GENRE1SUB         | ジャンル1（サブ） |
| TSREC_GENRE2            | ジャンル2（メイン） |
| TSREC_GENRE2SUB         | ジャンル2（サブ） |
| TSREC_GENRE3            | ジャンル3（メイン） |
| TSREC_GENRE3SUB         | ジャンル3（サブ） |
| TSREC_GENRE4            | ジャンル4（メイン） |
| TSREC_GENRE4SUB         | ジャンル4（サブ） |

### 動作原理
1. tsrecを実行すると、オプション処理などを行い、mirakurun サーバーからチャンネル情報を取得してスクリプト内部に保持します
2. mirakurun サーバーから番組情報を取得します
3. その中から指定されたサービスの次の番組情報を取得します
4. 次の番組の開始時刻の marginSec 秒分前まで待機（sleep）します
5. 待機が完了したら curl コマンドを呼び出し、番組を TS ファイルとして保存します
6. curl コマンドの終了を待たずに次に進みます
7. 番組の終了時刻の 1 分前まで待機します
8. 2に戻ります
終了するまでこれを繰り返します。

### TODO
動作確認
