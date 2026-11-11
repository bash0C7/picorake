# picorake計画

## 何を作るか

PicoRubyの上で動く、Rakefileの書式のtask定義と前提の解決。mrbgemとして作り、PicoRubyのVMに焼き込んで使う。

- `task`・`file`・`namespace`・`desc`・引数・`sh`・`ENV`を、rakeと同じ書き方で書ける
- 「作る必要があるか」の判定と、taskの走らせ方を差し替えられる
- 今すぐ1つのprocessで走らせる走り手と、`picorake`のCLIを持つ

## なぜ欲しいか

下書き。yommymonoで使いながら練る。

1. Rubyを入れずに動くRakefile。CRubyとrbenv、bundlerの組み合わせで起きる失敗(版の取り違え、shimの呼び合い、足りないgem)が、道具の作業から無くなる。CRubyはVMを焼く所だけに残る
2. 同じ宣言が、PicoRubyの動く所ならどこでも読める。Macのホスト、Cloudflare Workers(wasm)、ブラウザ(wasm)で、同じtaskの表を読む
3. 途中から再開できるRakefile。rakeは「作った物のファイルがあるか、新しいか」で作るかを決め、1つのprocessの中で終わる。picorakeは判定と走らせ方を差し替えられるので、作った物をDBに置き、taskをjob queueのjobとして別のprocessや別の日に進められる。落ちたtaskだけをやり直せる

## 使い方

### CLI

```text
picorake [-f FILE] [-T] [-n] [NAME=VALUE ...] [TASK[ARG,...] ...]
```

- `-f`はRakefileのpath。既定はcwdの`Rakefile`
- `-T`は`desc`の付いたtaskの一覧、`-n`は走らせずに走る順だけを出す
- `NAME=VALUE`は`ENV`に入る
- taskが例外で終わったら、終了コードを0以外にする

### ライブラリ

外の走り手は、CLIを通さずに表を読む。

```ruby
app = Picorake.application
app.load("Rakefile")
app.lookup("summary")                       # => Picorake::Task
app.plan("export:esa-digest", item_id: id)  # => 走る順のtaskの配列(作る必要のあるものだけ)
task.prerequisites                          # => ["page_text"]
task.needed?(args)
task.execute(args)
```

### 引数とitem

rakeのtaskの引数は、前提のtaskへ同じ名前で渡る。yommymonoはこれでitemを指す。新しい書式は足さない。

```ruby
file "page_text", [:item_id] do |t, args|
end

file "summary", [:item_id] => "page_text" do |t, args|
end
```

## Rakefileを誰がどう読むか

| 場所 | 読み方 |
| --- | --- |
| Macのホスト(CLI、yommymonoの処理役) | VMが実行時にsourceを`load`で読む。DSLは`Object`に`include`する(`load`で読んだfileの最上位のselfは、呼んだ側のselfと別のobjectになるので、`extend`では届かない) |
| Cloudflare Workers、ブラウザ(wasm) | buildで`mrbc`がapp.binへ焼き、VMの初期化でRakefileの最上位が走って表ができる。taskのblockはそこでは呼ばない |

- Rakefileの最上位には宣言だけを書く。ファイル、shell、DBに触るcodeはtaskのblockの中に置く(wasmでも最上位は走るため)
- 約束の範囲で書いたRakefileは、CRubyのrakeでもそのまま読める。移行の途中は、同じfileをどちらでも走らせられる

## 書式の約束

持つもの: `task`、`file`、`namespace`、`desc`、引数(`task :name, [:arg] => [:dep]`)、`sh`、`ENV`、`enhance`。

持たないもの: `FileList`、`rule`、`multitask`、`import`、`Rake::TestTask`、ファイルの更新時刻の比べ。

## 拡張

| 拡張のしかた | 例 |
| --- | --- |
| taskのclassを足す | `Picorake::Task`の子で`needed?`を上書きし、`Picorake.define_task(klass, ...)`でDSLのmethodにする(rakeの`FileTask`と同じ作り)。yommymonoは「そのitemの生成物がLocalStoreにあるか」で判定する`stored`を足す |
| shellを差し替える | `Picorake.shell`へ`run(command)`を持つobjectを置く。既定は`IO.popen`でshellを通す |
| 前提と動作を後から足す | `enhance` |
| 走り手を足す | ライブラリの`plan`・`needed?`・`execute`を読む。登録は要らない |

拡張は、Rakefileが読む純Rubyのfile(Macでは実行時の`require`、wasmではbuildで焼く)か、picorakeに依存するmrbgem(`spec.add_dependency "picorake"`)として置く。

## 外のmrbgemとの関係

- 芯のgem(`picorake`)は、PicoRubyの組み込みのclassだけに頼る。ファイル、IO、`ENV`に触らないので、wasmにもそのまま入る
- CLIのgem(`picorake-bin`)が、ファイルの有無の判定、`sh`、`ENV`、`load`を持ち、それに要るgemに依存する
- Rakefileが使えるのは、VMに焼いたgemだけ。CRubyのように実行時にgemを入れられない(純Rubyのfileは、Macなら実行時に`require`できる)
- 配る`picorake`のCLIは、標準のgemの組を持つ。それ以上が要るproject(yommymonoなど)は、自分のVMのbuild構成に`picorake.gembox`と自分のgemを足して焼く
- upstreamのPicoRubyの`picoruby-*`の名前は使わない

## repoの形

```text
mrbgems/
  picorake/        芯(mrbgem.rake、mrblib/)
  picorake-bin/    CLIと既定の判定・shell
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

- 処理の段: historyの段(素材化、解説、出口)を`stored`で宣言する。1つの段のreportを受けたHubが、宣言を見て次の段のjobを作る。Cloudflare側は前提のつながりだけを読む
- 道具の作業: Rakefileの`test`・`db:*`・`deploy`・`ship`・`dev:*`・`mac:*`・`jobs:*`・`feeds:*`をpicorakeへ移し、CRubyのRakefileにはVMとwasmを焼くtaskだけを残す

## 進める順

1. 芯(task、file、namespace、desc、引数、前提の解決、循環の検出、`enhance`、`plan`)と、今すぐ走らせる走り手。testをホストのVMとwasmで回す
2. `picorake-bin`(CLI、ファイルの判定、`sh`、`ENV`)と`picorake.gembox`
3. yommymonoのホストVMに入れ、段5(history)を`stored`の段として書く
4. yommymonoのpageと文字起こしを、同じ宣言へ移す
5. yommymonoの道具の作業をpicorakeへ移す
6. Homebrewのtapで配る

## 確かめていないこと

- `conf.gem github:`で、repoの中の`mrbgems/`の下のgemを指せるか
- Cloudflare向けのbuild構成(picoruby-cloudflare-worker-wasm)へgemを足せるか、mrblibのfileをapp.binに入れる方がよいか
- wasmのVMでpicotestを回す方法
- 約束の範囲のRakefileを、CRubyのrakeが同じに読むか
- CLIの起動が、CRubyのrakeより速いか
