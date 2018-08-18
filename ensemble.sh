#!/usr/bin/env bash

set -u

CUR_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CUR_DIR/functions"

TARGET="$1"

CONFIG_FILE="./config/config.yml"

python -c 'import sys, yaml, json; json.dump(yaml.safe_load(sys.stdin), sys.stdout, indent=2)' < $CONFIG_FILE > config.json
config=$(jq -Mc '.' config.json)

VALID="./images/valid"
TEST="./images/test"
DATA_VALID="./data/valid"
DATA_TEST="./data/test"

if [[ "$TARGET" = "valid" ]]; then
  DATA_DIR="$DATA_VALID"
  IMAGE_DIR="$VALID"
elif [[ "$TARGET" = "test" ]]; then
  DATA_DIR="$DATA_TEST"
  IMAGE_DIR="$TEST"
else
  echo 'Error: Invalid target name. Please specify `test` or `valid`.' 1>&2
  exit 1
fi

CONFUSION_MATRIX_OUTPUT=$(get_conf "$config"  ".ensemble.confusion_matrix_output" "1")
SLACK_UPLOAD=$(get_conf "$config"  ".ensemble.confusion_matrix_slack_upload" "0")
SLACK_CHANNELS=$(get_conf_array "$config"  ".ensemble.confusion_matrix_slack_channels" "general")
CLASSIFICATION_REPORT_OUTPUT=$(get_conf "$config"  ".ensemble.classification_report_output" "1")

MODELS=$(get_conf_array "$config"  ".ensemble.models" "")
if [[ "$MODELS" = "" ]]; then
  echo 'Error: ensemble.models in config.yml is empty.' 1>&2
  exit 1
fi
echo MODELS=$MODELS

for MODEL_AND_EPOCH in $MODELS; do
  # Remove epoch
  MODEL=${MODEL_AND_EPOCH%-*}
  # Determine MODEL_IMAGE_SIZE
  MODEL_IMAGE_SIZE=$(get_image_size "$MODEL")

  # If necessary image records do not exist, they are generated.
  if [ "$DATA_DIR/images-$TARGET-$MODEL_IMAGE_SIZE.rec" -ot "$IMAGE_DIR" ]; then
    echo "$DATA_DIR/images-$TARGET-$MODEL_IMAGE_SIZE.rec does not exist or is outdated." 1>&2
    echo "Generate image records for $TARGET." 1>&2
    if [[ "$TARGET" = "valid" ]]; then
      $CUR_DIR/gen_train.sh "$CONFIG_FILE" "$MODEL_IMAGE_SIZE"
    else
      $CUR_DIR/gen_test.sh "$CONFIG_FILE" "$MODEL_IMAGE_SIZE"
    fi
  fi

  # Check the number of image files. If it is different from previous one, regenerate images records
  diff --brief <(LC_ALL=C $CUR_DIR/counter.sh $IMAGE_DIR | sed -e '1d') <(cat $DATA_DIR/images-$TARGET-$MODEL_IMAGE_SIZE.txt) > /dev/null 2>&1
  if [ "$?" -eq 1 ]; then
    echo "$DATA_DIR/images-$TARGET-$MODEL_IMAGE_SIZE.rec is outdated." 1>&2
    echo "Generate image records for $TARGET." 1>&2
    if [[ "$TARGET" = "valid" ]]; then
      $CUR_DIR/gen_train.sh "$CONFIG_FILE" "$MODEL_IMAGE_SIZE" || exit 1
    else
      $CUR_DIR/gen_test.sh "$CONFIG_FILE" "$MODEL_IMAGE_SIZE" || exit 1
    fi
  fi
done

# Predict with specified model.
MODEL_PREFIX="$(date +%Y%m%d%H%M%S)-ensemble"
python ./ensemble.py "$CONFIG_FILE" "$TARGET" "$MODEL_PREFIX"

# save config.yml
CONFIG_LOG="logs/$MODEL_PREFIX-$TARGET-config.yml"
cp "$CONFIG_FILE" "$CONFIG_LOG" \
&& echo "Saved config file to \"$CONFIG_LOG\"" 1>&2

LABELS="model/$MODEL-labels.txt"
LABELS_TEST="$DATA_DIR/labels.txt"

diff --brief "$LABELS" "$LABELS_TEST"
if [[ "$?" -eq 1 ]]; then
  echo 'The directory structure of images/train and images/test is different.' 1>&2
  echo 'Skip making a confusion matrix and/or a classification report.' 1>&2
else
  # Make a confusion matrix from prediction results.
  if [[ "$CONFUSION_MATRIX_OUTPUT" = 1 ]]; then
    PREDICT_RESULTS_LOG="logs/$MODEL_PREFIX-$TARGET-results.txt"
    IMAGE="logs/$MODEL_PREFIX-$TARGET-confusion_matrix.png"
    python ./confusion_matrix.py "$CONFIG_FILE" "$LABELS" "$IMAGE" "$PREDICT_RESULTS_LOG"
    if [[ "$SLACK_UPLOAD" = 1 ]]; then
      python ./slack_file_upload.py "$SLACK_CHANNELS" "$IMAGE"
    fi
  fi
  # Make a classification report from prediction results.
  if [[ "$CLASSIFICATION_REPORT_OUTPUT" = 1 ]]; then
    PREDICT_RESULTS_LOG="logs/$MODEL_PREFIX-$TARGET-results.txt"
    REPORT="logs/$MODEL_PREFIX-$TARGET-classification_report.txt"
    python ./classification_report.py "$CONFIG_FILE" "$LABELS" "$PREDICT_RESULTS_LOG" "$REPORT"
    if [[ -e "$REPORT" ]]; then
      print_classification_report "$REPORT"
    else
      echo 'Error: classification report does not exist.' 1>&2
    fi
  fi
fi
