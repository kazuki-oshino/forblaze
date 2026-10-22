# 利用できるコマンドを表示
default:
    @just --list

test-one suite filter:
    python3 scripts/verify.py test-one '{{suite}}' '{{filter}}'

test:
    python3 scripts/verify.py test

build:
    python3 scripts/verify.py build

check:
    just check-architecture
    just test
    git diff --check

check-architecture:
    python3 scripts/check-architecture.py

signing-check:
    python3 scripts/install-app.py signing-check

install:
    python3 scripts/install-app.py install

run:
    python3 scripts/install-app.py run

# 外部へ送信しないブラウザー入力欄をローカルで開く
input-check:
    python3 -m http.server 8765 --bind 127.0.0.1 --directory tools/input-check

# 30分の実利用をRSSと型付き件数で観測（結果はbuild/observations）
observe seconds='1800':
    python3 scripts/observe-runtime.py --seconds '{{seconds}}'

# 終了済みの収録について、発話から認識・入力待ちのp50/p95と遅い更新の内訳を表示
input-latency:
    python3 scripts/input-latency.py

test-input-latency:
    python3 -m unittest discover -s scripts -p test_input_latency.py

# 合成音声で語彙・事前準備・4種類のバッファを独立比較。マイクと入力欄は使わない
improvement-check output:
    python3 scripts/improvement-check.py '{{output}}'

improvement-check-prepare output:
    python3 scripts/improvement-check.py '{{output}}' --prepare-model

# tapは音声を保存せず12秒間計測。rangeは専用のテスト入力欄へだけ文字を発行
improvement-device-check mode output:
    python3 scripts/improvement-device-check.py '{{mode}}' '{{output}}'

# 保存済み候補ログの解析・文脈生成・採点処理を検証
test-speech-candidates:
    python3 -m unittest discover -s scripts -p test_speech_candidate_eval.py

# 本文を含む固定コーパスをローカルへ保存。期待ラベルは推論前に別途記入する
speech-candidates-prepare logs build_id output:
    python3 scripts/speech_candidate_eval.py prepare '{{logs}}' '{{build_id}}' '{{output}}'

# 取得済みLayaで文脈量・候補順序を比較。録音や入力先へ接続しない
speech-candidates-eval corpus output style='word':
    sandbox-exec -p '(version 1) (allow default) (deny network*)' build/laya-eval/.venv/bin/python scripts/speech_candidate_eval.py run '{{corpus}}' '{{output}}' --option-style '{{style}}'

# 本番の状態パネルを固定状態で描画（認識・キー監視は起動しない）
panel-preview:
    python3 scripts/render-panel.py

# 本番の設定画面を明暗テーマ・最小サイズ・失敗状態で描画（実サービスは起動しない）
settings-preview:
    python3 scripts/render-settings.py

# 保存先はメモリ内。設定の操作を確認する
settings-preview-live:
    python3 scripts/render-settings.py --live

# 本番のMetalシェーダーを固定音量で描き、GPU時間も測る（マイクは使わない）
blaze-preview:
    python3 scripts/render-blaze.py

# 実際の透明ウィンドウで点火・消火・描画停止を確認（マイクは使わない）
blaze-preview-live seconds='12':
    python3 scripts/render-blaze.py --live '{{seconds}}'

# 独自の開始・終了SEを再生成（開発時だけffmpegが必要）
sounds:
    python3 scripts/generate-sounds.py

# 保存済みの原画からmacOSアプリアイコンの各サイズを再生成
icons:
    python3 scripts/generate-app-icon.py
    python3 scripts/generate-project.py

# Laya評価専用の依存をbuild内へ準備（モデルは取得済みのものを使う）
punctuation-eval-setup:
    uv venv --python python3.11 build/laya-eval/.venv
    uv pip install --python build/laya-eval/.venv/bin/python -r tools/laya-eval/requirements.txt

test-punctuation-eval:
    python3 -m unittest discover -s scripts -p test_punctuation_eval.py

# 合成50例×2質問形式×選択肢6順序。本文を含む結果はbuild内へ保存
punctuation-eval model=(env_var('HOME') / 'Models/laya-multilingual-mlx'):
    build/laya-eval/.venv/bin/python scripts/punctuation_eval.py --model '{{model}}'

# 完成文の比較形式をOSのネットワーク禁止下で再実行（macOS）
punctuation-eval-candidates model=(env_var('HOME') / 'Models/laya-multilingual-mlx'):
    sandbox-exec -p '(version 1) (allow default) (deny network*)' build/laya-eval/.venv/bin/python scripts/punctuation_eval.py --model '{{model}}' --prompts candidate_ja candidate_en --output build/laya-eval/results-candidates.json

# 本家Jev APIの比較評価。.envのTYPESAFE_API_KEYを使用する
jev-punctuation-eval-setup:
    uv venv --python python3.11 build/jev-eval/.venv
    uv pip install --python build/jev-eval/.venv/bin/python -r tools/jev-eval/requirements.txt

test-jev-punctuation-eval:
    python3 -m unittest discover -s scripts -p test_jev_punctuation_eval.py

# 本番Swiftアダプターを合成3例・1要求だけ実APIで確認（有料、.envを使用）
test-jev-punctuation-live:
    FORBLAZE_JEV_LIVE_TEST=1 just test-one macos JevPunctuationLiveTests

# 保存されているJevログのAPI回数・実トークン数・概算費用（追加のAPI通信なし）
jev-usage:
    python3 scripts/jev_usage.py

# 完了済み要求は同じoutputのjsonlから再利用。再測定時は別のoutputを指定する
jev-punctuation-eval output='build/jev-eval/results.json':
    build/jev-eval/.venv/bin/python scripts/jev_punctuation_eval.py --output '{{output}}'

# 取得済みJev-Style 0.8Bの配布元検証環境に合わせる
jev-style-punctuation-eval-setup:
    uv venv --python 3.12 build/jev-style-eval/.venv
    uv pip install --python build/jev-style-eval/.venv/bin/python -r tools/jev-style-eval/requirements.txt

test-jev-style-punctuation-eval:
    python3 -m unittest discover -s scripts -p test_jev_style_punctuation_eval.py

# 全50例をOSのネットワーク禁止下で評価。再測定は別のoutputを指定する
jev-style-punctuation-eval model=(env_var('HOME') / 'Models/jev-style-0.8b-v3-mlx') output='build/jev-style-eval/results.json':
    sandbox-exec -p '(version 1) (allow default) (deny network*)' build/jev-style-eval/.venv/bin/python scripts/jev_style_punctuation_eval.py --model '{{model}}' --output '{{output}}'

# 比較対象の2B版を固定リビジョンで取得。精度比較用にBF16だけをダウンロード
jev-style-2b-download:
    hf download chaoliangUNSW/Jev-Style-2B-Decision-v3-MLX --revision b86e4cbc6f420f5d7d1691299d62db272934ebf4 --exclude '8bit/*' --local-dir '{{env_var("HOME")}}/Models/jev-style-2b-v3-mlx'

jev-style-2b-punctuation-eval-setup:
    uv venv --python 3.12 build/jev-style-2b-eval/.venv
    uv pip install --python build/jev-style-2b-eval/.venv/bin/python -r tools/jev-style-2b-eval/requirements.txt

# 開発30例で単発4形式を比較し、好み一致と許容一致の形式を選ぶ
jev-style-2b-punctuation-develop output='build/jev-style-2b-eval/development.json':
    sandbox-exec -p '(version 1) (allow default) (deny network*)' build/jev-style-2b-eval/.venv/bin/python scripts/jev_style_2b_punctuation_eval.py develop --output '{{output}}'

# 元の50例と前回追加50例、選択肢順序・再現性の診断をネットワーク禁止下で測定
jev-style-2b-punctuation-eval output='build/jev-style-2b-eval/results.json' development='build/jev-style-2b-eval/development.json':
    sandbox-exec -p '(version 1) (allow default) (deny network*)' build/jev-style-2b-eval/.venv/bin/python scripts/jev_style_2b_punctuation_eval.py evaluate --development '{{development}}' --output '{{output}}'

# 数値の合成・方式選択と、既存の句読点評価を検証（NumPyを含む評価用環境）
test-punctuation-ensemble:
    build/laya-eval/.venv/bin/python -m unittest discover -s scripts -p 'test*punctuation*.py'

# SudachiとLayaの句読点復元実験。既存環境を変えず専用venvへ固定バージョンを取得
sudachi-punctuation-setup:
    uv venv --python 3.11 build/sudachi-punctuation-eval/.venv
    uv pip install --python build/sudachi-punctuation-eval/.venv/bin/python -r tools/sudachi-punctuation-eval/requirements.txt

test-sudachi-punctuation:
    build/sudachi-punctuation-eval/.venv/bin/python -m unittest discover -s scripts -p 'test*punctuation*.py'

sudachi-audio-prepare output:
    build/sudachi-punctuation-eval/.venv/bin/python scripts/prepare_sudachi_audio.py '{{output}}'

sudachi-punctuation-develop output='build/sudachi-punctuation-eval/choice-development.json':
    sandbox-exec -p '(version 1) (allow default) (deny network*)' build/sudachi-punctuation-eval/.venv/bin/python scripts/run_sudachi_choice.py develop --output '{{output}}'

sudachi-punctuation-evaluate apple development output:
    sandbox-exec -p '(version 1) (allow default) (deny network*)' build/sudachi-punctuation-eval/.venv/bin/python scripts/run_sudachi_choice.py evaluate --apple '{{apple}}' --development '{{development}}' --output '{{output}}'

# 合成音声だけを読む。アプリ本体の録音・設定・入力先には接続しない
sudachi-apple-audio jobs output:
    xcrun swiftc -parse-as-library scripts/sudachi_apple_audio.swift -o build/sudachi-punctuation-eval/apple-audio
    sandbox-exec -p '(version 1) (allow default) (deny network*)' build/sudachi-punctuation-eval/apple-audio '{{jobs}}' '{{output}}'

# 開発30例×11方式。外部APIは使わず、取得済みモデルを読み込む
punctuation-ensemble-explore backend output:
    #!/usr/bin/env bash
    set -euo pipefail
    case '{{backend}}' in
      laya) evaluation_python=build/laya-eval/.venv/bin/python ;;
      jev-style) evaluation_python=build/jev-style-eval/.venv/bin/python ;;
      *) echo 'backendはlayaまたはjev-style' >&2; exit 2 ;;
    esac
    sandbox-exec -p '(version 1) (allow default) (deny network*)' "$evaluation_python" scripts/run_punctuation_ensemble.py explore --backend '{{backend}}' --output '{{output}}'

# 開発データだけで3問・5問の方式と係数を固定。accuracyは正解数優先
punctuation-ensemble-select backend input output objective='balanced':
    build/laya-eval/.venv/bin/python scripts/run_punctuation_ensemble.py select --backend '{{backend}}' --input '{{input}}' --output '{{output}}' --objective '{{objective}}'

# 固定済みの方式を元の50例と新規50例で測定。既存の出力先は上書きしない
punctuation-ensemble-evaluate backend policy output:
    #!/usr/bin/env bash
    set -euo pipefail
    case '{{backend}}' in
      laya) evaluation_python=build/laya-eval/.venv/bin/python ;;
      jev-style) evaluation_python=build/jev-style-eval/.venv/bin/python ;;
      *) echo 'backendはlayaまたはjev-style' >&2; exit 2 ;;
    esac
    sandbox-exec -p '(version 1) (allow default) (deny network*)' "$evaluation_python" scripts/run_punctuation_ensemble.py evaluate --backend '{{backend}}' --input '{{policy}}' --output '{{output}}'
