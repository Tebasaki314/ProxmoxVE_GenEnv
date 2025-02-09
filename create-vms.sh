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

# テンプレートの設定を読み込む
templates=$(yq e '.templates' $CONFIG_FILE)

# SDNゾーン設定を読み込む
zone_id=$(yq e '.sdn.zone.id' $CONFIG_FILE)
zone_bridge=$(yq e '.sdn.zone.bridge' $CONFIG_FILE)
zone_mtu=$(yq e '.sdn.zone.mtu' $CONFIG_FILE)
zone_nodes=$(yq e '.sdn.zone.nodes' $CONFIG_FILE)
zone_ipam=$(yq e '.sdn.zone.ipam' $CONFIG_FILE)

# SDNゾーンを作成
echo "Creating SDN zone: $zone_id"
pvesh create /cluster/sdn/zones --zone $zone_id --bridge $zone_bridge --mtu $zone_mtu --nodes $zone_nodes --ipam $zone_ipam

# ネットワーク設定を読み込む
vnets=$(yq e '.sdn.vnets' $CONFIG_FILE)
for vnet in $(echo "$vnets" | yq e '.[] | @base64' -)
do
    _jq_vnet() {
        echo ${vnet} | base64 --decode | yq e ${1} -
    }

    vnet_name=$(_jq_vnet '.name')
    vnet_tag=$(_jq_vnet '.tag')
    subnets=$(_jq_vnet '.subnets')
    for subnet in $(echo "$subnets" | yq e '.[] | @base64' -)
    do
        _jq_subnet() {
            echo ${subnet} | base64 --decode | yq e ${1} -
        }

        subnet_cidr=$(_jq_subnet '.cidr')
        subnet_gateway=$(_jq_subnet '.gateway')
        subnet_snat=$(_jq_subnet '.snat')
        subnet_prefix=$(_jq_subnet '.prefix')

        echo "Creating network: $vnet_name with tag: $vnet_tag"
        # ネットワークの作成コマンドを実行
        pvesh create /cluster/sdn/vnets --vnet $vnet_name --zone $zone_id --tag $vnet_tag --cidr $subnet_cidr --gateway $subnet_gateway --snat $subnet_snat --prefix $subnet_prefix
    done
done

for template in $(echo "$templates" | yq e '.[] | @base64' -)
do
    _jq_template() {
        echo ${template} | base64 --decode | yq e ${1} -
    }

    # テンプレート設定を読み込む
    template_id=$(_jq_template '.template.id')
    template_from=$(_jq_template '.template.from')
    template_image=$(_jq_template '.template.image')
    template_user=$(_jq_template '.template.user')
    template_password=$(_jq_template '.template.password')
    template_sshkey=$(_jq_template '.template.sshkey')

    # クラウドイメージをダウンロード
    echo "Downloading cloud image"
    wget $template_from -O $template_image

    # クラウドイメージをProxmoxにインポート
    echo "Importing cloud image to Proxmox"
    qm create $template_id --name "ubuntu-template" --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0 --serial0 socket --vga serial0
    qm importdisk $template_id ubuntu-24.04-server-cloudimg-amd64.img local-lvm
    qm set $template_id --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-$template_id-disk-0
    qm set $template_id --ide2 local-lvm:cloudinit --boot c --bootdisk scsi0
    qm set $template_id --ciuser $template_user --sshkey $template_sshkey --cipassword $template_password --ipconfig0 ip=dhcp
    qm template $template_id
done

# 仮想マシンを作成する
for vm in $(echo "$vms" | yq e '.[] | @base64' -)
do
    _jq() {
        echo ${vm} | base64 --decode | yq e ${1} -
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
