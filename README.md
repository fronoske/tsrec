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
tsrec.rb -s 1048 -l log-TBS.txt -o /recorded/TBS &
tsrec.rb -s  101 -l log-BS1.txt -o /recorded/BS1 &
```
### 使用上の注意
- 本ツールでは暗号化の解除は行いません。mirakurun/mirakcからのストリームがすでに復号化されていることが前提です。
- 現時点では、本ツールの置かれたディレクトリに各種の一時ファイルを格納・更新します。書き込み権限に注意してください。

### コマンドラインオプション
```
Usage: tsrec [options]
    -s serviceId                     service ID
    -m marginSec                     margin sec to rec (default: 5)
    -o outDir                        Output directory
    -f outfileFormat                 out file format (default: %Y%m%d_%H%M %%T.ts)
    -j                               Output JSON file instad of text file
    -p command                       pipe command
    -a command                       command after each rec
    -d                               debug mode
    -l logfile                       output log (default: stderr)
    -u host:port                     mirakc host:port (default: localhost:40772)
    -S [GR|BS|CS|ALL]                Show services list
```
| オプション  | 説明 | デフォルト |
|:--|:--|:--:|
| -s ServiceID | 全録する対象のサービスID | なし（必須）|
| -m marginSec | 番組開始の何秒前から録画するか | `5` |
| -o outDir    | 出力先ディレクトリ | なし（ファイル保存をする場合は必須）|
| -f outputFormat | TSファイル名の書式（後述） | `%Y%m%d_%H%M %%T.ts` |
| -j           | 番組情報ファイルをテキスト形式でなく JSON 形式で出力する |
| -p command   | 標準入力を得て実行するコマンド（後述） | なし |
| -a command   | 番組の録画が終了した後に実行するコマンド（後述） | なし |
| -d           | 詳細ログ | `false` |
| -l logfile   | ログファイル | `stderr` |
| -u host:port | mirakurun/mirakcサーバーのホスト名とポート番号 | `localhost:40772` |
| -S \[GR\|BS\|CS\|ALL\] | 放送サービスの一覧を出力して終了する | なし |

### TSファイル名の書式
原則として strftime(3) に準じます。
加えて、以下の指定文字を使用できます。
- %%T：番組のタイトル
- %%S：サービス名（未実装）
- %%s: サービスID（未実装）

### pipeコマンド（実験的）
-pオプションにストリームを標準入力として受け付けるコマンドを指定することができます。
- -pオプションを指定すると、ストリームを標準出力に流します。
- このとき、-oオプションがない場合はファイルへの保存は行わず標準出力のみになり、-oオプションがある場合はファイルに保存しつつストリームを標準出力に流します。

コマンドの実行時には後述の環境変数を使用できます。（※シェルによる展開に注意してください。）
```
（例）
tsrec.rb -s 1048 -p 'ffmpeg -i - "${TSREC_OUT_PATH_BASE}.mp4"' # TSファイルを保存せずffmpegでMP4エンコードする
tsrec.rb -s 1048 -o /recorded/TBS -p 'ffmpeg -i - "${TSREC_OUT_PATH_BASE}.mp4"' # TSファイルを保存しつつMP4エンコードする
```

### postコマンド
-aオプションに各番組の録画完了後に実行するコマンドを指定することができます。
コマンドの実行時には後述の環境変数を使用できます。（※シェルによる展開に注意してください。）
```
（例）
tsrec.rb -s 1048 -o /recorded/TBS -a 'tsselect "${TSREC_OUT_PATH}" >> TBS-drop.log' # 録画完了後にtsselectでドロップチェックする
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
| TSREC_PROGRAM_ID        | mirakurun/mirakc の Program ID |
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
- tsrecプロセスをコントロールするためのコマンドを用意する
- サービスIDでなくチャンネル指定で複数サービスを同時に録画する
- もっとよい名前に改名する
