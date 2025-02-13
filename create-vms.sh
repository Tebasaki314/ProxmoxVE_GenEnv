#!/bin/bash

# 引数がなかった場合、設定ファイルを指定するようにヘルプを表示して終了する。
if [ $# -eq 0 ]; then
    echo "Usage: $0 <config_file>"
    exit 1
fi

# 引数から仮想マシンの設定ファイルを読み込む
CONFIG_FILE=$1

# YAMLファイルを解析するためにyqを使用
if ! command -v yq &> /dev/null
then
    echo "yqが見つかりません。インストールしてください。"
    exit 1
fi

# SDNゾーン設定を読み込む
zone_id=$(yq '.sdn.zone.id' $CONFIG_FILE | tr -d '"')
zone_type=$(yq '.sdn.zone.type' $CONFIG_FILE | tr -d '"')
zone_bridge=$(yq '.sdn.zone.bridge' $CONFIG_FILE | tr -d '"')
zone_mtu=$(yq '.sdn.zone.mtu' $CONFIG_FILE | tr -d '"')
# ノードのリストを取得して、カンマ区切りの文字列に変換
zone_nodes=$(yq '.sdn.zone.nodes | join(",")' $CONFIG_FILE | tr -d '"')
zone_ipam=$(yq '.sdn.zone.ipam' $CONFIG_FILE | tr -d '"')

# SDNゾーンを作成
echo "Creating SDN zone: $zone_id of type: $zone_type"
pvesh create /cluster/sdn/zones --type $zone_type --zone $zone_id --bridge $zone_bridge --mtu $zone_mtu --nodes "$zone_nodes" --ipam $zone_ipam

# ネットワーク設定を読み込む
vnets=$(yq '.sdn.zone.vnets' $CONFIG_FILE)
for vnet in $(echo "$vnets" | jq -r '.[] | @base64')
do
    _jq_vnet() {
        echo ${vnet} | base64 --decode | jq -r ${1}
    }

    vnet_name=$(_jq_vnet '.name' | tr -d '"')
    vnet_tag=$(_jq_vnet '.tag' | tr -d '"')
    subnets=$(_jq_vnet '.subnets')
    for subnet in $(echo "$subnets" | jq -r '.[] | @base64')
    do
        _jq_subnet() {
            echo ${subnet} | base64 --decode | jq -r ${1}
        }

        subnet_cidr=$(_jq_subnet '.cidr' | tr -d '"')
        subnet_gateway=$(_jq_subnet '.gateway' | tr -d '"')
        subnet_snat=$(_jq_subnet '.snat' | tr -d '"')
        subnet_prefix=$(_jq_subnet '.prefix' | tr -d '"')

        echo "Creating network: $vnet_name with tag: $vnet_tag"
        # ネットワークの作成コマンドを実行
        pvesh create /cluster/sdn/vnets --vnet $vnet_name --zone $zone_id --tag $vnet_tag --cidr $subnet_cidr --gateway $subnet_gateway --snat $subnet_snat --prefix $subnet_prefix
    done
done

# テンプレートの設定を読み込む
templates=$(yq '.templates' $CONFIG_FILE)

for template in $(echo "$templates" | jq -r '.[] | @base64')
do
    _jq_template() {
        echo ${template} | base64 --decode | jq -r ${1}
    }

    # テンプレート設定を読み込む
    template_id=$(_jq_template '.id')
    template_name=$(_jq_template '.name')
    template_from=$(_jq_template '.from')
    template_image=$(_jq_template '.image')
    template_user=$(_jq_template '.user')
    template_password=$(_jq_template '.password')
    template_sshkey=$(_jq_template '.sshkey')

    # クラウドイメージをダウンロード
    # もし、イメージが存在しない場合はダウンロードする
    if [ -f $template_image ]; then
        echo "Cloud image already exists"
    else
        echo "Downloading cloud image"
        wget $template_from -O $template_image
    fi

    # クラウドイメージをProxmoxにインポート
    echo "Importing cloud image to Proxmox"
    qm create $template_id --name "$template_name" --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0 --serial0 socket --vga serial0
    qm importdisk $template_id $template_image local-lvm
    qm set $template_id --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-$template_id-disk-0
    qm set $template_id --ide2 local-lvm:cloudinit --boot c --bootdisk scsi0
    qm set $template_id --ciuser $template_user --sshkey $template_sshkey --cipassword $template_password --ipconfig0 ip=dhcp
    qm template $template_id
done

# 仮想マシンの設定を読み込む
vms=$(yq '.vms' $CONFIG_FILE)

# 仮想マシンを作成する
for vm in $(echo "$vms" | jq -r '.[] | @base64')
do
    _jq() {
        echo ${vm} | base64 --decode | jq -r ${1}
    }

    node_name=$(_jq '.node_name')
    template_id=$(_jq '.template_id')
    name=$(_jq '.name')
    cores=$(_jq '.cores')
    memory=$(_jq '.memory')
    disk=$(_jq '.disk')
    lvm=$(_jq '.lvm')
    ip=$(_jq '.ip')
    bridge=$(_jq '.bridge')
    vlan_tag=$(_jq '.vlan_tag')

    echo "Creating VM: $name on node: $node_name with IP: $ip, bridge: $bridge, VLAN tag: $vlan_tag"
    # 仮想マシンのクローンを作成
    qm clone $template_id $name --name $name --full --target $node_name
    qm set $name --cores $cores --memory $memory --disk $disk --storage $lvm --net0 virtio,bridge=$bridge,tag=$vlan_tag --ipconfig0 ip=$ip/24
    qm start $name
done
