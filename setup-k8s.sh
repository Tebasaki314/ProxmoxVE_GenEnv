#!/bin/bash

# 仮想マシンの設定ファイルを読み込む
CONFIG_FILE="vm-config.yaml"

# YAMLファイルを解析するためにyqを使用
if ! command -v yq &> /dev/null
then
    echo "yqが見つかりません。インストールしてください。"
    exit 1
fi

# 仮想マシンの設定を読み込む
vms=$(yq e '.vms' $CONFIG_FILE)

# マスターノードの設定を取得
master=$(echo "$vms" | yq e '.[] | select(.name == "master") | @base64')

# ワーカーノードの設定を取得
workers=$(echo "$vms" | yq e '.[] | select(.name != "master") | @base64')

# マスターノードのIPアドレスを取得
master_ip=$(echo ${master} | base64 --decode | yq e '.ip' -)

# マスターノードにKubernetesをインストール
echo "Installing Kubernetes on master node"
ssh root@$master_ip "apt-get update && apt-get install -y kubeadm kubelet kubectl"

# マスターノードでクラスタを初期化
echo "Initializing Kubernetes cluster on master node"
ssh root@$master_ip "kubeadm init --apiserver-advertise-address=$master_ip --pod-network-cidr=10.244.0.0/16"

# クラスタの設定をローカルにコピー
ssh root@$master_ip "mkdir -p $HOME/.kube && cp -i /etc/kubernetes/admin.conf $HOME/.kube/config && chown $(id -u):$(id -g) $HOME/.kube/config"

# ワーカーノードをクラスタに参加させるためのコマンドを取得
join_command=$(ssh root@$master_ip "kubeadm token create --print-join-command")

# ワーカーノードをクラスタに参加させる
for worker in $(echo "$workers" | yq e '.[] | @base64' -)
do
    _jq() {
        echo ${worker} | base64 --decode | yq e ${1} -
    }

    worker_ip=$(_jq '.ip')
    echo "Joining worker node to the cluster"
    ssh root@$worker_ip "apt-get update && apt-get install -y kubeadm kubelet kubectl"
    ssh root@$worker_ip "$join_command"
done

# ネットワークプラグインをインストール
echo "Installing network plugin on master node"
ssh root@$master_ip "kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml"
