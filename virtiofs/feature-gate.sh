KV_NS="$(kubectl get kubevirt -A -o jsonpath='{.items[0].metadata.namespace}')"
KV_NAME="$(kubectl get kubevirt -A -o jsonpath='{.items[0].metadata.name}')"

kubectl -n "${KV_NS}" get kubevirt "${KV_NAME}" -o json \
  | jq '
      .spec.configuration.developerConfiguration.featureGates =
      ((.spec.configuration.developerConfiguration.featureGates // [])
        + ["EnableVirtioFsConfigVolumes"] | unique)
    ' \
  | kubectl apply -f -
