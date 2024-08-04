#!/bin/bash
# Copyright (C) 2024 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

set -e
echo "IMAGE_REPO=${IMAGE_REPO}"

WORKPATH=$(dirname "$PWD")
LOG_PATH="$WORKPATH/tests"
if ls $LOG_PATH/*.log 1> /dev/null 2>&1; then
    rm $LOG_PATH/*.log
    echo "Log files removed."
else
    echo "No log files to remove."
ip_address=$(hostname -I | awk '{print $1}')

function build_docker_images() {
    cd $WORKPATH
    git clone https://github.com/opea-project/GenAIComps.git
    cd GenAIComps
    git checkout ctao/animation

    docker build -t opea/whisper-gaudi:latest  -f comps/asr/whisper/Dockerfile_hpu .
    docker build -t opea/asr:latest  -f comps/asr/Dockerfile .
    docker build -t opea/llm-tgi:latest -f comps/llms/text-generation/tgi/Dockerfile .
    docker build -t opea/speecht5-gaudi:latest  -f comps/tts/speecht5/Dockerfile_hpu .
    docker build -t opea/tts:latest  -f comps/tts/Dockerfile .
    docker build -t opea/animation:latest -f comps/animation/Dockerfile_hpu .

    docker pull ghcr.io/huggingface/tgi-gaudi:2.0.1

    cd ..

    cd $WORKPATH/docker
    docker build --no-cache -t opea/avatarchatbot:latest -f Dockerfile .

    # cd $WORKPATH/docker/ui
    # docker build --no-cache -t opea/avatarchatbot-ui:latest -f docker/Dockerfile .

    docker images
}

function start_services() {
    cd $WORKPATH/docker/gaudi

    export ip_address=$(hostname -I | awk '{print $1}')
    export HUGGINGFACEHUB_API_TOKEN=$HUGGINGFACEHUB_API_TOKEN

    export TGI_LLM_ENDPOINT=http://$ip_address:3006
    export LLM_MODEL_ID=Intel/neural-chat-7b-v3-3
    export ASR_ENDPOINT=http://$ip_address:7066
    export TTS_ENDPOINT=http://$ip_address:7055
    export ANIMATION_ENDPOINT=http://$ip_address:3008

    export MEGA_SERVICE_HOST_IP=${ip_address}
    export ASR_SERVICE_HOST_IP=${ip_address}
    export TTS_SERVICE_HOST_IP=${ip_address}
    export LLM_SERVICE_HOST_IP=${ip_address}
    export ANIMATION_SERVICE_HOST_IP=${ip_address}

    export MEGA_SERVICE_PORT=8888
    export ASR_SERVICE_PORT=3001
    export TTS_SERVICE_PORT=3002
    export LLM_SERVICE_PORT=3007
    export ANIMATION_SERVICE_PORT=3008

    export ANIMATION_PORT=7860
    # export INFERENCE_MODE='wav2clip+gfpgan'
    export INFERENCE_MODE='wav2clip_only'
    export CHECKPOINT_PATH='src/Wav2Lip/checkpoints/wav2lip_gan.pth'
    export FACE='assets/avatar1.jpg'
    # export AUDIO='assets/eg3_ref.wav' # audio file path is optional, will use base64str as input if is 'None'
    export AUDIO='None'
    export FACESIZE=96
    export OUTFILE='/outputs/result.mp4'
    export GFPGAN_MODEL_VERSION=1.3
    export UPSCALE_FACTOR=1
    export FPS=10

    # sed -i "s/backend_address/$ip_address/g" $WORKPATH/docker/ui/svelte/.env

    if [[ "$IMAGE_REPO" != "" ]]; then
        # Replace the container name with a test-specific name
        echo "using image repository $IMAGE_REPO and image tag $IMAGE_TAG"
        sed -i "s#image: opea/avatarchatbot:latest#image: opea/avatarchatbot:${IMAGE_TAG}#g" compose.yaml
        sed -i "s#image: opea/avatarchatbot-ui:latest#image: opea/avatarchatbot-ui:${IMAGE_TAG}#g" compose.yaml
        sed -i "s#image: opea/*#image: ${IMAGE_REPO}/#g" compose.yaml
        echo "cat compose.yaml"
        cat compose.yaml
    fi

    # Start Docker Containers
    docker compose up -d
    n=0
    until [[ "$n" -ge 500 ]]; do
        docker logs tgi-gaudi-server > $LOG_PATH/tgi_service_start.log
        # check whisper and speecht5 services as well
        docker logs asr-service > $LOG_PATH/asr_service_start.log
        docker logs tts-service > $LOG_PATH/tts_service_start.log

        if grep -q Connected $LOG_PATH/tgi_service_start.log && \
            grep -q "initialized" $LOG_PATH/asr_service_start.log && \
            grep -q "initialized" $LOG_PATH/tts_service_start.log; then
            break
        fi
       sleep 1s
       n=$((n+1))
    done
    echo "All services are up and running"
    sleep 5s
}


function validate_megaservice() {
    cd $WORKPATH/docker/gaudi
    result=$(http_proxy="" curl http://${ip_address}:3009/v1/avatarchatbot -X POST -d @sample_whoareyou.json -H 'Content-Type: application/json')
    echo "result is === $result"
    if [[ $result == *"mp4"* ]]; then
        echo "Result correct."
    else
        docker logs whisper-service > $LOG_PATH/whisper-service.log
        docker logs asr-service > $LOG_PATH/asr-service.log
        docker logs speecht5-service > $LOG_PATH/tts-service.log
        docker logs tts-service > $LOG_PATH/tts-service.log
        docker logs tgi-gaudi-server > $LOG_PATH/tgi-gaudi-server.log
        docker logs llm-tgi-gaudi-server > $LOG_PATH/llm-tgi-gaudi-server.log
        docker logs animation-service > $LOG_PATH/animation-service.log

        echo "Result wrong."
        exit 1
    fi

}

#function validate_frontend() {
#    cd $WORKPATH/docker/ui/svelte
#    local conda_env_name="OPEA_e2e"
#    export PATH=${HOME}/miniforge3/bin/:$PATH
##    conda remove -n ${conda_env_name} --all -y
##    conda create -n ${conda_env_name} python=3.12 -y
#    source activate ${conda_env_name}
#
#    sed -i "s/localhost/$ip_address/g" playwright.config.ts
#
##    conda install -c conda-forge nodejs -y
#    npm install && npm ci && npx playwright install --with-deps
#    node -v && npm -v && pip list
#
#    exit_status=0
#    npx playwright test || exit_status=$?
#
#    if [ $exit_status -ne 0 ]; then
#        echo "[TEST INFO]: ---------frontend test failed---------"
#        exit $exit_status
#    else
#        echo "[TEST INFO]: ---------frontend test passed---------"
#    fi
#}

function stop_docker() {
    cd $WORKPATH/docker/gaudi
    docker compose stop && docker compose rm -f
}

function main() {

    stop_docker
    if [[ "$IMAGE_REPO" == "" ]]; then build_docker_images; fi
    start_services

    # validate_microservices
    validate_megaservice
    # validate_frontend

    stop_docker
    echo y | docker system prune

}

main
