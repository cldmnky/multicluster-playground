
.PHONY: all
all: create-clusters install-calico install-prometheus-operator install-metallb install-ingress install-kuard setup-skupper

.PHONY: create-clusters
create-clusters:
	@echo "=======> Creating clusters"
	@kind get clusters | grep -q central || kind create cluster --config=kind/central.yaml
	@kind get clusters | grep -q dc1 || kind create cluster --config=kind/dc1.yaml
	@kind get clusters | grep -q dc2 || kind create cluster --config=kind/dc2.yaml

.PHONY: delete-clusters
delete-clusters:
	@echo "=======> Deleting clusters"
	@kind delete clusters central dc1 dc2

.PHONY: install-calico
install-calico:
	@echo "=======> Installing Calico"
	@kubectl --context kind-central create -f cni/install-calico.yaml
	@kubectl --context kind-dc1 create -f cni/install-calico.yaml
	@kubectl --context kind-dc2 create -f cni/install-calico.yaml
	@sleep 20
	@kubectl --context kind-central create -f cni/central.yaml
	@kubectl --context kind-dc1 create -f cni/dc1.yaml
	@kubectl --context kind-dc2 create -f cni/dc2.yaml
	@for i in central dc1 dc2; do kubectl --context kind-$${i} wait -n local-path-storage \
		--for=condition=ready pod \
		--selector=app=local-path-provisioner \
		--timeout 90s; done
	@calicoctl --allow-version-mismatch --context kind-central create -f cni/ip-pool-central.yaml
	@calicoctl --allow-version-mismatch --context kind-dc1 create -f cni/ip-pool-dc1.yaml
	@calicoctl --allow-version-mismatch --context kind-dc2 create -f cni/ip-pool-dc2.yaml

.PHONY: install-prometheus-operator
install-prometheus-operator:
	@echo "=======> Installing Prometheus Operator"
	@for i in central dc1 dc2; do kubectl --context kind-$${i} create namespace monitoring; done
	@kubectl --context kind-central create -f prometheus-operator/install.yaml
	@kubectl --context kind-dc1 create -f prometheus-operator/install.yaml
	@kubectl --context kind-dc2 create -f prometheus-operator/install.yaml
	@for i in central dc1 dc2; do kubectl --context kind-$${i} wait --namespace monitoring \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/name=prometheus-operator \
		--timeout=90s; done

.PHONY: install-metallb
install-metallb:
	@echo "=======> Installing MetalLB"
	@kubectl --context kind-central apply -f metallb/install.yaml
	@kubectl --context kind-dc1 apply -f metallb/install.yaml
	@kubectl --context kind-dc2 apply -f metallb/install.yaml
	@for i in central dc1 dc2; do kubectl --context kind-$${i} wait --namespace metallb-system \
		--for=condition=ready pod \
		--selector=app=metallb \
		--timeout=90s; done
	@kubectl --context kind-central apply -f metallb/central.yaml
	@kubectl --context kind-dc1 apply -f metallb/dc1.yaml
	@kubectl --context kind-dc2 apply -f metallb/dc2.yaml

.PHONY: install-ingress
install-ingress:
	@echo "=======> Installing Ingress"
	@kubectl --context kind-central apply -f ingress/install.yaml
	@kubectl --context kind-dc1 apply -f ingress/install.yaml
	@kubectl --context kind-dc2 apply -f ingress/install.yaml
	@for i in central dc1 dc2; do kubectl --context kind-$${i} wait --namespace ingress-nginx \
		--for=condition=ready pod \
		--selector app.kubernetes.io/component=controller \
		--timeout=90s; done

.PHONY: install-kuard
install-kuard:
	@echo "=======> Installing Kuard"
	@kubectl --context kind-central create namespace kuard
	@kubectl --context kind-dc1 create namespace kuard
	@kubectl --context kind-dc1 apply -n kuard -f kuard/install-dc1.yaml
	@kubectl --context kind-dc2 create namespace kuard
	@kubectl --context kind-dc2 apply -n kuard -f kuard/install-dc2.yaml

.PHONY: setup-skupper
setup-skupper:
	@echo "=======> Setting up Skupper"
	@$(SKUPPER) --context kind-central -n kuard init --site-name central
	@$(SKUPPER) --context kind-dc1 init -n kuard --site-name dc1
	@$(SKUPPER) --context kind-dc2 init -n kuard --site-name dc2
	@echo "=======> Setup tokens"
	@$(SKUPPER) --context kind-central -n kuard token create --expiry 1h dc1-to-central.token
	@$(SKUPPER) --context kind-central -n kuard token create --expiry 1h dc2-to-central.token
	@echo "=======> Connect sites"
	@$(SKUPPER) --context kind-dc1 -n kuard link create dc1-to-central.token && rm dc1-to-central.token
	@$(SKUPPER) --context kind-dc2 -n kuard link create dc2-to-central.token && rm dc2-to-central.token
	@echo "=======> Create services"
	@$(SKUPPER) --context kind-dc1 -n kuard service create kuard-skupper 80
	@$(SKUPPER) --context kind-dc2 -n kuard service create kuard-skupper 80
	@echo "=======> Bind services"
	@$(SKUPPER) --context kind-dc1 -n kuard service bind kuard-skupper service kuard
	@$(SKUPPER) --context kind-dc2 -n kuard service bind kuard-skupper service kuard
	@echo "=======> Expose service in central"
	@kubectl --context kind-central -n kuard apply -f kuard/expose.yaml

.PHONY: setup-submariner
setup-submariner:
	@echo "=======> Setting up Submariner"; \
	export CENTRAL=$$(kubectl --context kind-central get nodes --field-selector metadata.name=central-control-plane -o=jsonpath='{.items[0].status.addresses[0].address}') && \
	export DC1=$$(kubectl --context kind-dc1 get nodes --field-selector metadata.name=dc1-control-plane -o=jsonpath='{.items[0].status.addresses[0].address}') && \
	export DC2=$$(kubectl --context kind-dc2 get nodes --field-selector metadata.name=dc2-control-plane -o=jsonpath='{.items[0].status.addresses[0].address}') && \
	kubectl --context kind-central -n default run subm --image openshift/origin-cli -- /bin/bash -c "trap : TERM INT; sleep infinity & wait" && \
	kubectl --context kind-central wait --namespace default \
		--for=condition=ready pod subm \
		--timeout=90s && \
	kubectl --context kind-central -n default exec -it subm -- mkdir -p /root/.kube && \
	kubectl --context kind-central -n default cp $${KUBECONFIG} subm:/root/.kube/config && \
	kubectl --context kind-central -n default exec -it subm -- kubectl config set-cluster kind-central --server https://$$CENTRAL:6443/ && \
	kubectl --context kind-central -n default exec -it subm -- kubectl config set-cluster kind-dc1 --server https://$$DC1:6443/ && \
	kubectl --context kind-central -n default exec -it subm -- kubectl config set-cluster kind-dc2 --server https://$$DC2:6443/ && \
	kubectl --context kind-central -n default exec -it subm -- bash -c "curl -Ls http://get.submariner.io | bash" && \
	sleep 5 && \
	kubectl --context kind-central -n default exec -it subm -- kubectl --context kind-dc1 label node dc1-worker submariner.io/gateway=true && \
	kubectl --context kind-central -n default exec -it subm -- kubectl --context kind-dc2 label node dc2-worker submariner.io/gateway=true && \
	kubectl --context kind-central -n default exec -it subm -- /root/.local/bin/subctl deploy-broker --context kind-central && \
	kubectl --context kind-central create clusterrole ds-reader --verb=get,list,watch --resource=daemonsets && \
	kubectl --context kind-central create clusterrolebinding --clusterrole=ds-reader --serviceaccount submariner-operator:submariner-operator submariner-ds && \
	sleep 5 && \
	kubectl --context kind-central -n default exec -it subm -- /root/.local/bin/subctl join --context kind-dc1 broker-info.subm --clusterid kind-dc1 --natt=false && \
	kubectl --context kind-dc1 create clusterrole ds-reader --verb=get,list,watch --resource=daemonsets && \
	kubectl --context kind-dc1 create clusterrolebinding --clusterrole=ds-reader --serviceaccount submariner-operator:submariner-operator submariner-ds && \
	kubectl --context kind-dc2 -n submariner-operator delete pods -l name=submariner-operator && \
	kubectl --context kind-central -n default exec -it subm -- /root/.local/bin/subctl join --context kind-dc2 broker-info.subm --clusterid kind-dc2 --natt=false && \
	kubectl --context kind-dc2 create clusterrole ds-reader --verb=get,list,watch --resource=daemonsets && \
	kubectl --context kind-dc2 create clusterrolebinding --clusterrole=ds-reader --serviceaccount submariner-operator:submariner-operator submariner-ds && \
	kubectl --context kind-dc2 -n submariner-operator delete pods -l name=submariner-operator && \
	sleep 5 && \
	kubectl --context kind-central -n default exec -it subm -- /root/.local/bin/subctl --context kind-central show all
	#kubectl --context kind-central -n default exec -it subm -- /root/.local/bin/subctl --context kind-dc1 export service --namespace ingress-nginx ingress-nginx-controller
	#kubectl --context kind-central -n default exec -it subm -- /root/.local/bin/subctl --context kind-dc2 export service --namespace ingress-nginx ingress-nginx-controller
	

.PHONY: skupper-dashboard
skupper-dashboard:
	@echo "=======> Skupper dashboard"
	@kubectl --context kind-central -n kuard port-forward services/skupper 8888:8080 & open https://localhost:8888; wait %1

.PHONY: kuard-web
kuard-web:
	@echo "=======> Kuard web"
	@open http://localhost:8080/

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

## Tool Binaries
SKUPPER ?= $(LOCALBIN)/skupper
CALICOCTL ?= $(LOCALBIN)/calicoctl


## Tool Versions
SKUPPER_VERSION ?= 1.2.0

.PHONY: skupper
skupper: $(SKUPPER) ## Download skupper locally if necessary.
$(SKUPPER): $(LOCALBIN)
	test -s $(LOCALBIN)/skupper || GOBIN=$(LOCALBIN) go install github.com/skupperproject/skupper/cmd/skupper@$(SKUPPER_VERSION)
