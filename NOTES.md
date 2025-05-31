CertSlurp AKS Deployment & Troubleshooting Guide

1. Prerequisites
	•	You must be an owner of the resource group (check in Azure Portal or via az role assignment list).

⸻

2. Build & Upload Binaries

Cross-compile Go binaries for Linux:

GOOS=linux GOARCH=amd64 go build -o certslurpctl ./cmd/certslurpctl
GOOS=linux GOARCH=amd64 go build -o slurpload ./cmd/slurpload

Copy to remote host (if needed):

scp -i ~/.ssh/bitbucket_demo slurpload azureuser@<IP>:slurpload
scp -i ~/.ssh/bitbucket_demo certslurpctl azureuser@<IP>:certslurpctl


⸻

3. Build & Push Docker Images

Build Docker image for your app:

docker buildx build --platform linux/amd64 -f Dockerfile.certslurpd . -t certslurp7623.azurecr.io/certslurp/certslurpd:latest --load

Log in to Azure Container Registry (ACR):

az acr login --name certslurp7623

Push the image:

docker push certslurp7623.azurecr.io/certslurp/certslurpd:latest


⸻

4. Attach ACR to AKS

So that your AKS cluster can pull images from ACR:

az aks update -n certslurp-aks -g certslurp --attach-acr certslurp7623


⸻

5. Access AKS Cluster

Get kubeconfig for kubectl:

az aks get-credentials --resource-group certslurp --name certslurp-aks
kubectl get nodes


⸻

6. Deploy with Helm

Deploy or upgrade with necessary parameters:

helm upgrade --install certslurp ./certslurp \
  --set image.repository=certslurp7623.azurecr.io/certslurp/certslurpd \
  --set image.tag=latest \
  --set worker.replicas=512 \    # Or scale as needed
  --set etcd.root_password='...' \
  --set etcd.user_password='...' \
  --set certslurp.cluster_key='...' \
  --set certslurp.api_tokens='...'

Tip: You can override values in values.yaml using --set. Make sure you restart or redeploy pods if you change secrets/env vars!

⸻

7. Bootstrap and Authorize etcd

Create and grant user/role for your application:

kubectl exec etcd-0 -- etcdctl --user root:<rootpw> user add certslurpapp:<userpw>
kubectl exec etcd-0 -- etcdctl --user root:<rootpw> role add certslurpapp
kubectl exec etcd-0 -- etcdctl --user root:<rootpw> user grant-role certslurpapp certslurpapp
kubectl exec etcd-0 -- etcdctl --user root:<rootpw> role grant-permission certslurpapp --prefix=true readwrite ""


⸻

8. Troubleshooting Common Issues

Pod Stuck in Pending
	•	Check pod events:

kubectl describe pod <pod-name>

	•	Most common reasons: Insufficient CPU/memory, insufficient pod slots per node, taints, or affinity/selector mismatch.

	•	Each AKS node defaults to max 30 pods unless you specify higher via kubelet.

Scaling Pods
	•	Each node only supports a set number of pods (pods allocatable).
	•	E.g., 4 vCPU Standard_D4s_v3 node → 30 pods max unless cluster is tuned for more.
	•	To scale, adjust worker count:

helm upgrade --install certslurp ./certslurp --set worker.replicas=140

(Scale down if hitting pod limits.)

Head/Controller Pods Pending
	•	Usually caused by lack of available resources/pod slots.
	•	Try scaling workers down or increasing node count.

Env Var/Secret Not Updating
	•	After changing a Helm value or secret, you must redeploy/restart the affected pods to pick up new environment variables.

kubectl rollout restart deployment <deployment-name>

Or just re-run your helm upgrade.

Image Pull Issues
	•	Confirm ACR is attached:

az aks update -n certslurp-aks -g certslurp --attach-acr certslurp7623


	•	Check for image pull errors in pod events.

Checking Cluster Capacity
	•	Check how many pods can run per node:

kubectl describe node <node-name>

Look at Capacity and Allocatable for pods.

	•	See pod distribution across nodes:

kubectl get pods -o wide



⸻

9. Useful Commands Cheat Sheet
	•	List all pods, their status and which node they’re on:

kubectl get pods -o wide


	•	See live logs from a pod:

kubectl logs -f <pod-name>


	•	SSH into a running container:

kubectl exec -it <pod-name> -- /bin/sh


	•	Describe node resources:

kubectl describe node <node-name>


	•	Check Helm release status:

helm status certslurp


	•	See environment variables for a pod:

kubectl exec <pod-name> -- printenv



⸻

If you’re troubleshooting, always start with:
	•	kubectl get pods
	•	kubectl describe <pod>
	•	kubectl logs <pod>


To forward ports for certslurpctl:

kubectl port-forward deployment/certslurpd-head 8080:8080