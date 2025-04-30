1. Apply new CRD
    $ kubectl apply -f manifests/crds/harvesterhci.io_networkfilesystems.yaml

2. If not use storage network, on node have:
    $ sysctl -w net.bridge.bridge-nf-call-iptables=1
