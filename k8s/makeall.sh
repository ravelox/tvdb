#!/bin/bash

set -x

for f in tvdb-namespace.yaml \
	tvdb-storage-pv.yaml \
	tvdb-storage-deployment.yaml \
	tvdb-storage-service.yaml \
	tvdb-app-deployment.yaml \
	tvdb-app-service.yaml
do
	cat ${f}
	echo "---"
done > k8s-all.yaml
