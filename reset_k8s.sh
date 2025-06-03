helm uninstall certslurp

# Delete app deployment
kubectl delete deployment --all

# Delete the etcd statefulset and the etcd bootstrap job
kubectl delete statefulset etcd
kubectl delete job etcd-bootstrap-user

# Delete the headless service
kubectl delete svc etcd-headless

# Delete etcd-related secrets
kubectl delete secret etcd-root-secret certslurpd-etcd-creds

# Delete persistent volume claims for etcd
kubectl get pvc | grep etcd | awk '{print $1}' | xargs kubectl delete pvc

# Delete any stuck pods
kubectl delete pod --all
