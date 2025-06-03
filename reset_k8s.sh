kubectl delete deployment --all
kubectl delete secret etcd-root-secret certslurpd-etcd-creds
kubectl delete svc etcd-headless
kubectl delete statefulset etcd
kubectl delete job etcd-bootstrap-user
kubectl get pvc | grep etcd | awk '{print $1}' | xargs kubectl delete pvc
kubectl delete pods --all --force --grace-period=0