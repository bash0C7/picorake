# picorake計画

## 何を作るか

PicoRubyの上で動く、Rakefileの書式のtask定義と前提の解決。mrbgemとして作り、PicoRubyのVMに焼き込んで使う。

- `task`・`file`・`namespace`・`desc`・引数・`sh`・`ENV`を、rakeと同じ書き方と同じ意味で書ける
- 「作る必要があるか」の判定を、taskのclassで差し替えられる
- 今すぐ1つのprocessで走らせる走り手と、`picorake`のCLIを持つ
- 外の走り手(job queueなど)が、1回に1段ずつ進められる

## なぜ欲しいか

下書き。yommymonoで使いながら練る。

1. 途中から再開できるRakefile。rakeの「無い物、古い物だけ作る」を、job queueの上で1段ずつ、別のprocessや別の日に進められる。落ちた段だけをやり直せる。書式は、Rubyistが一番よく知っているRakefileのまま
2. Rubyを入れずに動くRakefile。CRubyとrbenv、bundlerの組み合わせで起きる失敗(版の取り違え、shimの呼び合い、足りないgem)が、道具の作業から無くなる。CRubyはVMを焼く所だけに残る
3. PicoRubyの動く所なら、同じRakefileが読める。Mac、Linux、マイコン(R2P2)、ブラウザ

## rakeとの関係

同じもの:

- 書式: `task`、`file`、`namespace`、`desc`、`task default:`、引数付きの`task :name, [:arg] => [:dep]`、`enhance`
- 前提の解決: 前提を先に深さ優先で走らせ、1回の実行で同じtaskは1度だけ走らせ、循環していれば止める
- 引数: 前提が同じ名前の引数を宣言しているときだけ、その値を前提へ渡す
- `file`の判定: ファイルが無いか、前提のどれかが自分より新しいときに作る。普通の`task`の時刻は常に「今」
- CLI: `-f`、`-T`、`-n`、`NAME=VALUE`、失敗したら0以外の終了コード。`sh`は失敗したら例外

違うもの:

| 違い | 理由 |
| --- | --- |
| 並列(`multitask`、`-j`)を持たない | 今すぐ走らせる走り手を単純に保つ。並列は外の走り手(複数のworker)に任せる |
| DSLを`Object`にprivateで`include`する | `load`で読んだfileの最上位のselfが、呼んだ側のselfと別のobjectになり、`extend`では届かない |
| Rakefileが使えるgemは、VMに焼いたものだけ | PicoRubyに、実行時にgemを入れる仕組みが無い。純Rubyのfileは、翻訳器のある所なら実行時に`require`できる |
| `FileList`、`rule`、`import`、`directory`、`clean`、`rakelib/`の自動の読み込み、上のdirectoryへのRakefileの探索を持たない | 最初の約束を小さく保つ。要るものが出たら足す |

## 使い方

### CLI

```text
picorake [-f FILE] [-T] [-n] [NAME=VALUE ...] [TASK[ARG,...] ...]
```

- `-f`はRakefileのpath。既定はcwdの`Rakefile`
- `-T`は`desc`の付いたtaskの一覧、`-n`は走らせずに走る順だけを出す
- `NAME=VALUE`は`ENV`に入る

### ライブラリ

```ruby
app = Picorake.application
app.load("Rakefile")
app.lookup("summary")                       # => Picorake::Task
app.plan("export:esa-digest", item_id: id)  # => 作る必要のあるtaskを、走る順に並べた配列
task.needed?(args)
task.execute(args)
```

### 引数とitem

rakeの引数の渡り方のまま、itemを指す。新しい書式は足さない。

```ruby
file "page_text", [:item_id] do |t, args|
end

file "summary", [:item_id] => "page_text" do |t, args|
end
```

## Rakefileを誰がどう読むか

読めるかどうかは、VMにRubyの翻訳器と、textを取る手段があるかで決まる。

| 場所 | 読み方 |
| --- | --- |
| Mac、Linux | VMが実行時に`load`で読む |
| R2P2(マイコン) | flashのfileを`load`で読む。shellが無いので`sh`は使えない |
| ブラウザ | HTTPで取ったtextを`eval`する |
| 翻訳器を焼いていないVM(例: yommymonoのCloudflare Worker) | buildでRakefileごと焼き込む。最上位はVMの初期化で走るので、最上位には宣言だけを書く |

## 判定

| taskのclass | 「作る必要があるか」 | 時刻の取り方 |
| --- | --- | --- |
| `Task` | 常に作る | 今 |
| `FileTask` | 無いか、前提の方が新しい | `File::Stat`の更新時刻(CLIのVMに`mruby-file-stat`を焼く) |
| 使う側が足すclass | `FileTask`と同じ決まり | 使う側が決める(例: yommymonoはLocalStoreに置いた時刻) |

## jobとして走らせる

rakeと同じく、目標から前提を辿る。1回のclaimで1段だけ進める。

1. 外の走り手は、目標のtaskの名前と引数でjobを作る
2. claimした側が`plan(目標, 引数)`を出し、先頭の1段だけ`execute`する
3. 段が残っていれば、次の段の名前を添えてjobを戻す。残っていなければ完了にする

- 段の間の受け渡しは、作った物だけに限る。メモリ上の値は次の段へ渡らない
- 作り直すときは、その段の作った物を消してjobを戻す。後ろの段は時刻の比べで作り直される
- 前提が2つ以上ある段も、`plan`が全部の前提を見るので、揃うまで走らない
- job queueの側は、Rakefileを読まなくてよい

## 拡張

| 拡張のしかた | 例 |
| --- | --- |
| taskのclassを足す | `FileTask`の子で時刻の取り方を上書きし、`Picorake.define_task(klass, ...)`でDSLのmethodにする |
| shellを差し替える | `Picorake.shell`へ`run(command)`を持つobjectを置く。既定は`IO.popen`でshellを通し、出力を1行ずつ流す |
| 前提と動作を後から足す | `enhance` |
| 走り手を足す | ライブラリの`plan`・`needed?`・`execute`を読む。登録は要らない |

拡張は、Rakefileが読む純Rubyのfileか、picorakeに依存するmrbgem(`spec.add_dependency "picorake"`)として置く。

## 外のmrbgemとの関係

- 芯のgem(`picorake`)は、PicoRubyの組み込みのclassだけに頼る。ファイル、IO、`ENV`に触らないので、ブラウザやマイコンのVMにもそのまま入る
- CLIのgem(`picorake-bin`)が、`FileTask`の時刻、`sh`、`ENV`、`load`を持ち、それに要るgemに依存する
- 配る`picorake`のCLIは、標準のgemの組を持つ。それ以上が要るprojectは、自分のVMのbuild構成に`picorake.gembox`と自分のgemを足して焼く
- upstreamのPicoRubyの`picoruby-*`の名前は使わない

## repoの形

```text
mrbgems/
  picorake/        芯(mrbgem.rake、mrblib/)
  picorake-bin/    CLI、FileTaskの時刻、sh
picorake.gembox    2つのgemと、CLIが使う標準のgemの組
build_config/      CLIのVMを焼く構成
test/              picotest
docs/plan.md
```

## 配り方

- yommymonoは、自分のホストVMのbuild構成に`picorake.gembox`を足して使う
- `picorake`のCLIは、書式の約束がyommymonoで固まってから、自分のHomebrewのtap(`bash0C7/homebrew-tap`)に、焼いた物(bottle)付きのformulaで置く。入れる側でCRubyは要らない
- upstreamのPicoRubyには安定版のtagが無いので、picorakeの版ごとにPicoRubyのcommitを固定する

## yommymonoでの使い方

- 処理の段: historyの段(素材化、解説、出口)を、LocalStoreに置いた時刻で判定するtaskのclass(`stored`)で宣言する。D1のjobは目標(出口のlane)で作り、Macの処理役がclaimのたびに1段進めて、次の段のlaneでjobを戻す。CloudflareのWorkerはRakefileを読まない
- 道具の作業: Rakefileの`test`・`db:*`・`deploy`・`ship`・`dev:*`・`mac:*`・`jobs:*`・`feeds:*`をpicorakeへ移し、CRubyのRakefileにはVMとwasmを焼くtaskだけを残す

## 進める順

1. 芯(`Task`、`FileTask`の決まり、namespace、desc、引数、前提の解決、循環の検出、`enhance`、`plan`)と、今すぐ走らせる走り手
2. `picorake-bin`(CLI、`File::Stat`の時刻、`sh`、`ENV`)と`picorake.gembox`
3. yommymonoのホストVMに入れ、段5(history)を`stored`の段として書く
4. yommymonoのpageと文字起こしを、同じ宣言へ移す
5. yommymonoの道具の作業をpicorakeへ移す
6. Homebrewのtapで配る

## 確かめていないこと

- `mruby-file-stat`をホストのVMに焼けるか、`File::Stat#mtime`が取れるか
- `conf.gem github:`で、repoの中の`mrbgems/`の下のgemを指せるか
- Linux、Windows、R2P2、ブラウザで、外のRakefileを読めるか(build構成を読んだだけ)
- ブラウザとマイコンのVMで、picotestを回す方法
- 約束の範囲のRakefileを、CRubyのrakeが同じに読むか
- CLIの起動が、CRubyのrakeより速いか
