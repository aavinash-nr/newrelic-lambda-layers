#!/usr/bin/env bash

set -Eeuo pipefail

# S3 bucket naming: one bucket per region, named "${BUCKET_NAME_PREFIX}-${region}"
# Override via GitHub repo variable BUCKET_NAME_PREFIX for testing
BUCKET_NAME_PREFIX="${BUCKET_NAME_PREFIX:-nr-layers}"

# Tracks regions that were skipped (pre-flight failures or publish-time failures)
SKIPPED_REGIONS=()
# Regions that failed pre-flight — never attempted during publish
PREFLIGHT_SKIP=()

# If the workflow ran preflight once in a dedicated job and passed the result
# via PREFLIGHT_SKIP_REGIONS (comma-separated), load it now so publish_layer
# never runs preflight again inside Docker or per-matrix runners.
if [[ -n "${PREFLIGHT_SKIP_REGIONS:-}" ]]; then
  IFS=',' read -ra PREFLIGHT_SKIP <<< "$PREFLIGHT_SKIP_REGIONS"
fi

# Extracts only the AWS error code from CLI output, e.g. "AccessDenied" from
# "An error occurred (AccessDenied) when calling the HeadBucket operation: ..."
# First tries the canonical AWS CLI error format to avoid false positives from
# other parenthesized words in SSL/curl/timeout error messages (e.g. "(certificate
# verify failed)" would otherwise extract "certificate"). Falls back to any
# parenthesized token if the specific format is not present (e.g. connection errors).
# Never leaks ARNs, account IDs, bucket names, or message bodies.
function aws_error_code {
  local output="$1"
  local code
  # Primary: match the standard AWS CLI "An error occurred (Code)" pattern
  code=$(echo "$output" | grep -oP 'error occurred \(\K[A-Za-z][A-Za-z0-9]+(?=\))' | head -1 || true)
  # Fallback: any parenthesized word (catches curl/connection error codes)
  if [[ -z "$code" ]]; then
    code=$(echo "$output" | grep -oP '(?<=\()[A-Za-z][A-Za-z0-9]+(?=\))' | head -1 || true)
  fi
  echo "${code:-unknown error}"
}

# Runs an AWS CLI command for a specific region.
# Any failure is treated as a regional issue — exit code 2 (skip this region).
# On success, returns 0.
function run_aws_for_region {
  local output
  local exit_code

  output=$("$@" 2>&1) && exit_code=0 || exit_code=$?

  if [[ $exit_code -eq 0 ]]; then
    echo "$output"
    return 0
  fi

  echo "WARNING: AWS command failed for region ($(aws_error_code "$output")) — will skip" >&2
  return 2
}

# Returns 0 if the region should be skipped (failed pre-flight).
function region_should_skip {
  local region="$1"
  for r in "${PREFLIGHT_SKIP[@]}"; do
    [[ "$r" == "$region" ]] && return 0
  done
  return 1
}

# Checks one region during pre-flight (called in parallel background subshells).
# Writes "ok" or "skip:<reason>" to $out_file. Uses aws_error_code for safe
# error reporting — no ARNs, account IDs, or bucket names are emitted.
function _preflight_check_region {
  # Disable errexit inside this function: all error paths are handled explicitly
  # via "if !" guards. Without this, any unguarded command added in the future
  # would silently kill the background subshell before writing to $out_file,
  # producing a misleading "timed out or crashed" result in the parent.
  set +e

  local region="$1"
  local bucket_prefix="$2"
  local out_file="$3"
  local bucket="${bucket_prefix}-${region}"

  # 3. S3 bucket accessible
  local s3_output
  if ! s3_output=$(aws --cli-connect-timeout 5 --cli-read-timeout 10 \
      s3api head-bucket --bucket "$bucket" --region "$region" 2>&1); then
    echo "skip:S3 bucket not accessible ($(aws_error_code "$s3_output"))" > "$out_file"
    return
  fi

  # 4. S3 bucket writable (deterministic key — always overwrites, never accumulates)
  local probe_key=".preflight-probe"
  local s3w_output
  if ! s3w_output=$(aws --cli-connect-timeout 5 --cli-read-timeout 10 \
      s3api put-object \
      --bucket "$bucket" --key "$probe_key" --body /dev/null \
      --region "$region" 2>&1); then
    echo "skip:S3 bucket not writable ($(aws_error_code "$s3w_output"))" > "$out_file"
    return
  fi
  # Clean up probe object; best-effort, ignore errors
  aws --cli-connect-timeout 5 --cli-read-timeout 10 \
    s3api delete-object --bucket "$bucket" --key "$probe_key" \
    --region "$region" 2>/dev/null || true

  # 5. Lambda API reachable
  local lambda_output
  if ! lambda_output=$(aws --cli-connect-timeout 5 --cli-read-timeout 10 \
      lambda get-account-settings --region "$region" 2>&1); then
    echo "skip:Lambda API not accessible ($(aws_error_code "$lambda_output"))" > "$out_file"
    return
  fi

  echo "ok" > "$out_file"
}

# Pre-flight checks run ONCE before any publishing begins:
#   1. Validate AWS credentials (fatal)
#   2. ECR Public auth reachable (fatal — global, us-east-1 only)
#   3-5. Per-region in parallel: S3 accessible, S3 writable, Lambda API reachable
# All AWS CLI calls use --cli-connect-timeout 5 --cli-read-timeout 10 to
# fail fast during regional outages instead of hanging for 30-60 seconds.
# Regions that fail any per-region check are added to PREFLIGHT_SKIP and
# never attempted. Only the AWS error code is logged — no ARNs, account IDs,
# bucket names, or message bodies are printed.
function preflight_check {
  echo "=== Pre-flight checks ==="

  # 1. Credentials — fatal; write result artifact so notify job can report it.
  local creds_output
  creds_output=$(aws --cli-connect-timeout 5 --cli-read-timeout 10 \
    sts get-caller-identity 2>&1) || {
    local err_code
    err_code=$(aws_error_code "$creds_output")
    echo "FATAL: AWS credentials check failed (${err_code})." >&2
    mkdir -p /tmp/layer-results
    {
      echo "label=Pre-flight"
      echo "status=failure"
      echo "reason=AWS credentials invalid or missing (${err_code})"
    } > /tmp/layer-results/preflight-failure.txt
    exit 1
  }
  echo "Credentials OK"

  # 2. ECR Public auth — fatal; stdout is the auth token so discard it,
  #    capture only stderr for the error code.
  #    Inside $(), stdout is already the capture pipe. Redirect order:
  #      2>&1  → stderr joins the capture pipe (so error text lands in ecr_err)
  #      >/dev/null → stdout (the token) is discarded
  #    Do NOT swap the order: >/dev/null 2>&1 would send stderr to /dev/null too,
  #    leaving ecr_err empty and aws_error_code returning "unknown error" on failure.
  local ecr_err
  if ! ecr_err=$(aws --cli-connect-timeout 5 --cli-read-timeout 10 \
      ecr-public get-login-password --region us-east-1 2>&1 >/dev/null); then
    local err_code
    err_code=$(aws_error_code "$ecr_err")
    echo "FATAL: ECR Public auth failed (${err_code})." >&2
    mkdir -p /tmp/layer-results
    {
      echo "label=Pre-flight"
      echo "status=failure"
      echo "reason=ECR Public auth failed (${err_code})"
    } > /tmp/layer-results/preflight-failure.txt
    exit 1
  fi
  echo "ECR Public auth OK"

  # Checks 3-5 run in parallel — each region spawns a background subshell that
  # writes "ok" or "skip:<reason>" to a temp file; the parent collects after wait.
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local pids=()

  local region
  for region in "${REGIONS[@]}"; do
    _preflight_check_region "$region" "$BUCKET_NAME_PREFIX" "${tmp_dir}/${region}" &
    pids+=($!)
  done

  # Wait for all background checks — use || true so a non-zero subshell exit
  # (e.g. from set -e) doesn't abort the parent before we read all results.
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done

  # Collect results in REGIONS order to keep output deterministic
  for region in "${REGIONS[@]}"; do
    local result_file="${tmp_dir}/${region}"
    local result
    result=$(cat "$result_file" 2>/dev/null || echo "skip:no result (subshell timed out or crashed)")

    if [[ "$result" == "ok" ]]; then
      echo "  [OK]   ${region} — S3 accessible and writable, Lambda API accessible"
    else
      local reason="${result#skip:}"
      echo "  [SKIP] ${region} — ${reason}"
      PREFLIGHT_SKIP+=("$region")
      SKIPPED_REGIONS+=("${region} (pre-flight: ${reason})")
    fi
  done

  local skip_count=${#PREFLIGHT_SKIP[@]}
  local total=${#REGIONS[@]}

  # Cleanup temp dir regardless of outcome — placed here so it runs before
  # the early exit below, not after it (which would leak the directory).
  rm -rf "$tmp_dir"

  # If more than half of all regions failed, treat it as a systemic issue
  # (e.g. bad credentials, account suspended, widespread outage) — fail fast
  # rather than attempting a partial publish.
  # Using skip_count*2 > total instead of skip_count > total/2 to avoid integer
  # division truncation ambiguity on odd region counts (both are equivalent, but
  # the multiplication form makes the "more than half" intent unambiguous).
  if [[ $total -gt 0 && $(( skip_count * 2 )) -gt $total ]]; then
    echo "FATAL: ${skip_count}/${total} regions failed pre-flight — likely a systemic AWS or credentials issue." >&2
    mkdir -p /tmp/layer-results
    {
      echo "label=Pre-flight"
      echo "status=failure"
      echo "reason=${skip_count}/${total} regions failed pre-flight (systemic issue)"
    } > /tmp/layer-results/preflight-failure.txt
    exit 1
  fi

  echo "Pre-flight complete: $(( total - skip_count ))/${total} regions ready, ${skip_count} skipped"
  echo "========================="
}

# Report any regions that were skipped due to AWS infrastructure errors.
# Writes to /tmp/layer-results/skipped-regions.txt so CI workflows can surface
# them in Slack. In CI the publish step mounts /tmp/layer-results from the runner
# so this file is visible to subsequent workflow steps.
# Automatically runs on script exit via trap — no need to call manually.
function report_skipped_regions {
  local original_exit=$?

  if [[ ${#SKIPPED_REGIONS[@]} -gt 0 ]]; then
    echo ""
    echo "========================================="
    echo "WARNING: The following regions were SKIPPED:"
    mkdir -p /tmp/layer-results
    for entry in "${SKIPPED_REGIONS[@]}"; do
      echo "  - ${entry}"
      # Write only the region name to the file — detail stays in workflow logs.
      # Slack uses this file to show a clean list of region names.
      echo "${entry%% *}" >> /tmp/layer-results/skipped-regions.txt
    done
    echo "These regions may need a manual re-publish once the AWS issues are resolved."
    echo "========================================="
    echo ""
  fi

  # Preserve the original exit code — skipped regions alone don't fail the job.
  # A non-zero original_exit means a real (non-infra) error occurred; keep that failure.
  exit $original_exit
}

# Auto-report skipped regions when the script exits
trap report_skipped_regions EXIT

REGIONS=(
  # sa-east-1
  # me-central-1
  me-south-1
  # eu-central-2
  # eu-north-1
  # eu-south-2
  # eu-west-3
  # eu-south-1
  # eu-west-2
  # eu-west-1
  # eu-central-1
  # ca-central-1
  # ap-northeast-1
  # ap-southeast-2
  # ap-southeast-1
  # ap-northeast-2
  # ap-northeast-3
  # ap-south-1
  # ap-south-2
  # ap-southeast-4
  # ap-southeast-3
  # af-south-1
  # us-east-1
  # us-east-2
  us-west-1
  # us-west-2
)

EXTENSION_DIST_DIR=extensions
EXTENSION_DIST_ZIP=extension.zip
EXTENSION_DIST_PREVIEW_FILE=preview-extensions-ggqizro707

EXTENSION_VERSION=2.4.6

function list_all_regions {
    aws ec2 describe-regions \
      --all-regions \
      --query "Regions[].{Name:RegionName}" \
      --output text | sort
}

function fetch_extension {
    arch=$1

    url="https://github.com/newrelic/newrelic-lambda-extension/releases/download/v${EXTENSION_VERSION}/newrelic-lambda-extension.${arch}.zip"
    rm -rf $EXTENSION_DIST_DIR $EXTENSION_DIST_ZIP
    curl -L $url -o $EXTENSION_DIST_ZIP
}

function download_extension {
    fetch_extension $@

    unzip $EXTENSION_DIST_ZIP -d .
    rm -f $EXTENSION_DIST_ZIP
}

function layer_name_str() {
    rt_part="LambdaExtension"
    arch_part=""

    case $1 in
    "java8.al2")
      rt_part="Java8"
      ;;
    "java11")
      rt_part="Java11"
      ;;
    "java17")
      rt_part="Java17"
      ;;
    "java21")
      rt_part="Java21"
      ;;
    "python3.9")
      rt_part="Python39"
      ;;
    "python3.10")
      rt_part="Python310"
      ;;
    "python3.11")
      rt_part="Python311"
      ;;
    "python3.12")
      rt_part="Python312"
      ;;
    "python3.13")
      rt_part="Python313"
      ;;
    "python3.14")
      rt_part="Python314"
      ;;
    "python")
      rt_part="Python"
      ;;
    "nodejs20.x")
      rt_part="NodeJS20X"
      ;;
    "nodejs22.x")
      rt_part="NodeJS22X"
      ;;
    "nodejs24.x")
      rt_part="NodeJS24X"
      ;;
    "nodejs")
      rt_part="NodeJS"
      ;;
    "ruby3.2")
      rt_part="Ruby32"
      ;;
    "ruby3.3")
      rt_part="Ruby33"
      ;;
    "ruby3.4")
      rt_part="Ruby34"
      ;;
    "dotnet")
      rt_part="Dotnet"
      ;;
    esac

    case $2 in
    "arm64")
      arch_part="ARM64"
      ;;
    "x86_64")
      arch_part=""
      ;;
    esac

    echo "NewRelic${rt_part}${arch_part}"
}

function s3_prefix() {
    name="nr-extension"

    case $1 in
    "java8.al2")
      name="java-8"
      ;;
    "java11")
      name="java-11"
      ;;
    "java17")
      name="java-17"
      ;;
    "java21")
      name="java-21"
      ;;
    "python3.9")
      name="nr-python3.9"
      ;;
    "python3.10")
      name="nr-python3.10"
      ;;
    "python3.11")
      name="nr-python3.11"
      ;;
    "python3.12")
      name="nr-python3.12"
      ;;
    "python3.13")
      name="nr-python3.13"
      ;;
    "python3.14")
      name="nr-python3.14"
      ;;
    "python")
      name="nr-python"
      ;;
    "nodejs20.x")
      name="nr-nodejs20.x"
      ;;
    "nodejs22.x")
      name="nr-nodejs22.x"
      ;;
    "nodejs24.x")
      name="nr-nodejs24.x"
      ;;
    "nodejs")
      name="nr-nodejs"
      ;;
    "ruby3.2")
      name="nr-ruby3.2"
      ;;
    "ruby3.3")
      name="nr-ruby3.3"
      ;;
    "ruby3.4")
      name="nr-ruby3.4"
      ;;
    "dotnet")
      name="nr-dotnet"
      ;;
    esac

    echo $name
}

function agent_name_str() {
    local runtime=$1
    local agent_name
   
    case $runtime in
        "provided")
            agent_name="provided"
            ;;
        "dotnet")
            agent_name="Dotnet"
            ;;
        "nodejs"|"nodejs20.x"|"nodejs22.x"|"nodejs24.x")
            agent_name="Node"
            ;;
        "ruby3.2"|"ruby3.3"|"ruby3.4")
            agent_name="Ruby"
            ;;
        "java8.al2"|"java11"|"java17"|"java21")
            agent_name="Java"
            ;;
        "python"|"python3.9"|"python3.10"|"python3.11"|"python3.12"|"python3.13"|"python3.14")
            agent_name="Python"
            ;;
        *)
            agent_name="none"
            ;;
    esac

    echo $agent_name
}

function hash_file() {
    if command -v md5sum &> /dev/null ; then
        md5sum $1 | awk '{ print $1 }'
    else
        md5 -q $1
    fi
}

function publish_public_layer {
  layer_name=$1
  bucket_name=$2
  s3_key=$3
  description=$4
  arch_flag=$5
  region=$6
  runtime_name=$7
  compat_list=("${@:8}")

  local layer_version
  local publish_result
  layer_version=$(run_aws_for_region \
    aws lambda publish-layer-version \
    --layer-name ${layer_name} \
    --content "S3Bucket=${bucket_name},S3Key=${s3_key}" \
    --description "${description}"\
    --license-info "Apache-2.0" $arch_flag \
    --compatible-runtimes ${compat_list[*]} \
    --region "$region" \
    --output text \
    --query Version) && publish_result=0 || publish_result=$?

  if [[ $publish_result -ne 0 ]]; then
    echo "SKIPPING region ${region} for ${runtime_name} — PublishLayerVersion failed"
    SKIPPED_REGIONS+=("${region} (${runtime_name} - PublishLayerVersion failed)")
    return 2
  fi

  echo "Published ${runtime_name} layer version ${layer_version} to ${region}"

  echo "Setting public permissions for ${runtime_name} layer version ${layer_version} in ${region}"
  local perms_result
  run_aws_for_region \
    aws lambda add-layer-version-permission \
    --layer-name ${layer_name} \
    --version-number "$layer_version" \
    --statement-id public \
    --action lambda:GetLayerVersion \
    --principal "*" \
    --region "$region" && perms_result=0 || perms_result=$?

  if [[ $perms_result -ne 0 ]]; then
    echo "SKIPPING region ${region} for ${runtime_name} v${layer_version} — AddLayerVersionPermission failed"
    SKIPPED_REGIONS+=("${region} (${runtime_name} v${layer_version} - AddLayerVersionPermission failed)")
    return 2
  fi

  echo "Public permissions set for ${runtime_name} layer version ${layer_version} in region ${region}"
  return 0
}


# Mark preflight done if skip list was pre-loaded from env
_PREFLIGHT_DONE="${PREFLIGHT_SKIP_REGIONS:+true}"
_PREFLIGHT_DONE="${_PREFLIGHT_DONE:-false}"

function publish_layer {
    # Run pre-flight once before the first publish attempt
    if [[ "$_PREFLIGHT_DONE" == "false" ]]; then
      preflight_check
      _PREFLIGHT_DONE=true
    fi

    layer_archive=$1
    region=$2
    runtime_name=$3
    arch=$4
    newrelic_agent_version=${5:-"none"}
    slim=${6:-""}

    # Skip regions that already failed pre-flight
    if region_should_skip "$region"; then
      echo "SKIPPING region ${region} — failed pre-flight check"
      return 2
    fi

    agent_name=$( agent_name_str $runtime_name )
    layer_name=$( layer_name_str $runtime_name $arch )

    hash=$( hash_file $layer_archive | awk '{ print $1 }' )

    bucket_name="${BUCKET_NAME_PREFIX}-${region}"
    s3_key="$( s3_prefix $runtime_name )/${hash}.${arch}.zip"

    compat_list=( $runtime_name )
    if [[ $runtime_name == "provided" ]]
    then compat_list=("provided" "provided.al2" "provided.al2023" "dotnetcore3.1")
    fi

    if [[ $runtime_name == "dotnet" ]]
    then compat_list=("dotnet6" "dotnet8" "dotnet10")
    fi

    if [[ $runtime_name == "python" ]]
    then compat_list=("python3.9" "python3.10" "python3.11" "python3.12" "python3.13" "python3.14")
    fi

    if [[ $runtime_name == "nodejs" ]]
    then compat_list=("nodejs20.x" "nodejs22.x" "nodejs24.x")
    fi

    echo "Uploading ${layer_archive} to s3://${bucket_name}/${s3_key}"
    local s3_result
    run_aws_for_region \
      aws --region "$region" s3 cp $layer_archive "s3://${bucket_name}/${s3_key}" && s3_result=0 || s3_result=$?

    if [[ $s3_result -ne 0 ]]; then
      echo "SKIPPING region ${region} for ${runtime_name} — S3 upload failed"
      SKIPPED_REGIONS+=("${region} (${runtime_name} - S3 upload failed)")
      return 2
    fi

   # Check whether $region is in the REGIONS array using exact element matching.
   # The old pattern ([[ ${REGIONS[*]} =~ $region ]]) used substring match on the
   # joined string, which could incorrectly match a region name that is a substring
   # of another (e.g. "us-east-1" matching inside "us-east-10" if it existed).
   arch_flag=""
   for _r in "${REGIONS[@]}"; do
     if [[ "$_r" == "$region" ]]; then
       arch_flag="--compatible-architectures $arch"
       break
     fi
   done

    base_description="New Relic Layer for ${runtime_name} (${arch})"
    extension_info=" with New Relic Extension v${EXTENSION_VERSION}"

    if [[ $newrelic_agent_version != "none" ]]; then
        if [[ $agent_name != "provided" ]]; then
            agent_info=" and ${agent_name} agent v${newrelic_agent_version}"
        else
            base_description="New Relic Layer for OS only runtime (${arch})"
            agent_info=""
        fi

        description="${base_description}${extension_info}${agent_info}"
    else
        if [[ $agent_name == "Java" ]]; then
            description="${base_description}${extension_info}"
        else
            description="${base_description}."
        fi
    fi

    echo "Publishing ${runtime_name} layer to ${region}"
    if [[ $slim == "slim" ]]; then
        echo "Publishing ${runtime_name} slim layer to ${region}"
        layer_name="${layer_name}-slim"
        base_description="New Relic slim Layer without opentelemetry for ${runtime_name} (${arch})"
        description="${base_description}${extension_info}${agent_info}"
    fi

    local publish_result
    publish_public_layer $layer_name $bucket_name $s3_key "$description" "$arch_flag" "$region" "$runtime_name" "${compat_list[@]}" && publish_result=0 || publish_result=$?

    # Return code 2 = AWS infra error (region skipped, continue with others)
    # Return code 1 = our error (credentials, params, etc. — stop immediately)
    # Return code 0 = success
    return $publish_result
}


function publish_docker_ecr {
    layer_archive=$1
    runtime_name=$2
    arch=$3
    slim=${4:-""}

    if [[ ${arch} =~ 'arm64' ]];
    then 
        arch_flag="-arm64"
        platform="linux/arm64"
    else 
        arch_flag=""
        platform="linux/amd64"
    fi

    version_flag=$(echo "$runtime_name" | sed 's/[^0-9]//g')
    language_flag=$(echo "$runtime_name" | sed 's/[0-9].*//')

    if [[ ${runtime_name} =~ 'extension' ]]; then
    version_flag=$EXTENSION_VERSION
    language_flag="lambdaextension"
    fi

    if [[ ${runtime_name} =~ 'dotnet' ]]; then
    version_flag=""
    arch_flag=${arch}
    fi

    if [[ $runtime_name == "python" || $runtime_name == "nodejs" ]]; then
    version_flag=""
    arch_flag=${arch}
    fi

    slim_flag=""
    if [ "$slim" == "slim" ]; then
        slim_flag="-slim"
    fi

    # Remove 'dist/' prefix
    if [[ $layer_archive == dist/* ]]; then
      file_without_dist="${layer_archive#dist/}"
      echo "File without 'dist/': $file_without_dist"
    else
      file_without_dist=$layer_archive
      echo "File does not start with 'dist/': $file_without_dist"
    fi

    # Override via GitHub repo variable ECR_REPO_NAME for testing (e.g. q6k3q1g1)
    repository="${ECR_REPO_NAME:-x6n7b2o2}"

    # copy dockerfile
    cp ../Dockerfile.ecrImage .

    # Authenticate with ECR Public. Add timeouts so a regional outage doesn't stall
    # the build indefinitely. Check auth explicitly before piping to docker login so
    # a failed token fetch produces a clear error rather than a confusing docker error.
    echo "Authenticating with ECR Public (public.ecr.aws/${repository})..."
    local ecr_err
    if ! ecr_err=$(aws --cli-connect-timeout 5 --cli-read-timeout 10 \
        ecr-public get-login-password --region us-east-1 2>&1 >/dev/null); then
      echo "ERROR: ECR Public auth failed ($(aws_error_code "$ecr_err"))" >&2
      return 1
    fi
    aws --cli-connect-timeout 5 --cli-read-timeout 10 \
      ecr-public get-login-password --region us-east-1 \
      | docker login --username AWS --password-stdin "public.ecr.aws/${repository}"

    echo "docker buildx build --platform ${platform} -t layer-nr-image-${language_flag}-${version_flag}${arch_flag}${slim}:latest \
    -f Dockerfile.ecrImage \
    --build-arg layer_zip=${layer_archive} \
    --build-arg file_without_dist=${file_without_dist} \
    ."

    docker buildx build --platform ${platform} -t layer-nr-image-${language_flag}-${version_flag}${arch_flag}${slim}:latest \
    -f Dockerfile.ecrImage \
    --build-arg layer_zip=${layer_archive} \
    --build-arg file_without_dist=${file_without_dist} \
    .

    echo "docker tag layer-nr-image-${language_flag}-${version_flag}${arch_flag}${slim}:latest public.ecr.aws/${repository}/newrelic-lambda-layers-${language_flag}${slim_flag}:${version_flag}${arch_flag}"
    docker tag layer-nr-image-${language_flag}-${version_flag}${arch_flag}${slim}:latest public.ecr.aws/${repository}/newrelic-lambda-layers-${language_flag}${slim_flag}:${version_flag}${arch_flag}
    echo "docker push public.ecr.aws/${repository}/newrelic-lambda-layers-${language_flag}${slim_flag}:${version_flag}${arch_flag}"
    docker push public.ecr.aws/${repository}/newrelic-lambda-layers-${language_flag}${slim_flag}:${version_flag}${arch_flag}

    # delete dockerfile
    rm -rf Dockerfile.ecrImage
}

function publish_docker_hub {
  layer_archive=$1
  runtime_name=$2
  arch=$3
  if [[ ${arch} =~ 'arm64' ]];
  then arch_flag="-arm64"
  else arch_flag=""
  fi
  version_flag=$(echo "$runtime_name" | sed 's/[^0-9]//g')
  language_flag=$(echo "$runtime_name" | sed 's/[0-9].*//')
  # Remove 'dist/' prefix
  if [[ $layer_archive == dist/* ]]; then
    file_without_dist="${layer_archive#dist/}"
    echo "File without 'dist/': $file_without_dist"
  else
    file_without_dist=$layer_archive
    echo "File does not start with 'dist/': $file_without_dist"
  fi

  # copy dockerfile
  cp ../Dockerfile.ecrImage .
  echo "docker build -t ${language_flag}-${version_flag}${arch_flag}:latest \
  -f Dockerfile.ecrImage \
  --build-arg layer_zip=${layer_archive} \
  --build-arg file_without_dist=${file_without_dist} \
  ."
  docker build -t ${language_flag}-${version_flag}${arch_flag}:latest \
  -f Dockerfile.ecrImage \
  --build-arg layer_zip=${layer_archive} \
  --build-arg file_without_dist=${file_without_dist} \
  .
  echo "docker tag ${language_flag}-${version_flag}${arch_flag}:latest newrelic/newrelic-lambda-layers:${language_flag}-${version_flag}${arch_flag}"
  docker tag ${language_flag}-${version_flag}${arch_flag}:latest newrelic/newrelic-lambda-layers:${language_flag}-${version_flag}${arch_flag}
  echo "docker push newrelic/newrelic-lambda-layers:${language_flag}-${version_flag}${arch_flag}"
  docker push newrelic/newrelic-lambda-layers:${language_flag}-${version_flag}${arch_flag}
}
