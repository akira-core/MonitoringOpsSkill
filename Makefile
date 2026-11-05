SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help
LAB := scripts/lab
VLAB := scripts/lab/vector

##@ Cluster
up: ## Create kind cluster and install the whole stack (idempotent)
	@scripts/up.sh
down: ## Delete the kind cluster
	@scripts/down.sh
status: ## Show pods in all lab namespaces
	@\
	 for ns in monitoring clickhouse logging keda vmagent-lab vector-lab; do echo "== $$ns"; kubectl --context kind-monops -n $$ns get pods; done
grafana: ## Port-forward Grafana to localhost:3000 (prints admin password)
	@scripts/grafana.sh

##@ vmagent autoscale / drain lab
load: ## Set synthetic load: make load N=8  (avalanche replicas, ~1000 samples/s each)
	@$(LAB)/load.sh $(N)
pin: ## Pin shard count via KEDA: make pin N=3 | make pin N=off
	@$(LAB)/pin.sh $(N)
outage-start: ## Remote storage down (vminsert -> 0)
	@$(LAB)/outage.sh start
outage-stop: ## Remote storage back up
	@$(LAB)/outage.sh stop
queue: ## Per-pod on-disk / total pending bytes
	@$(LAB)/queue-status.sh
inspect-pvc: ## Mount orphaned queue PVCs and report pending bytes + drain log
	@$(LAB)/inspect-pvc.sh
scenario: ## End-to-end scale-down-during-outage drain scenario (DRAIN=auto|disk|skip)
	@DRAIN=$(or $(DRAIN),auto) $(LAB)/scenario-drain.sh
gaps: ## Scrape-gap measurement during a roll: make gaps N=3 (reshard) | make gaps N=upgrade
	@$(LAB)/measure-gaps.sh $(N)

##@ Vector autoscale / drain lab
vload: ## Set synthetic log load: make vload N=6  (loggen replicas, ~200 lines/s each)
	@$(VLAB)/load.sh $(N)
vpin: ## Pin Vector replicas via KEDA: make vpin N=3 | make vpin N=off
	@$(VLAB)/pin.sh $(N)
voutage-start: ## Vector downstream down (rotel -> 0)
	@$(VLAB)/outage.sh start
voutage-stop: ## Vector downstream back up
	@$(VLAB)/outage.sh stop
vqueue: ## Per Vector pod: disk-buffer records/bytes
	@$(VLAB)/queue-status.sh
vinspect-pvc: ## Read the disk-buffer ledger of unmounted Vector PVCs
	@$(VLAB)/inspect-pvc.sh
vscenario: ## Scale Vector 3->2 during a rotel outage, then inspect the removed PVC
	@$(VLAB)/scenario.sh

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2} /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5)}' $(MAKEFILE_LIST)
.PHONY: up down status grafana load pin outage-start outage-stop queue inspect-pvc scenario gaps \
	vload vpin voutage-start voutage-stop vqueue vinspect-pvc vscenario help
