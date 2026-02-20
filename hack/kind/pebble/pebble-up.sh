#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: 2024 SAP SE or an SAP affiliate company and Gardener contributors
#
# SPDX-License-Identifier: Apache-2.0

set -o errexit
set -o pipefail

PEBBLE_IMAGE=ghcr.io/letsencrypt/pebble:latest
CHALLSRV_IMAGE=ghcr.io/letsencrypt/pebble-challtestsrv:latest
PEBBLE_CERTIFICATE_VALIDITY=${PEBBLE_CERTIFICATE_VALIDITY:-7776000} # default validity 90 days

source $(dirname ${0})/../common.sh /..

create_certificate() {
  # generate certificate for ACME server
  current_dir=$PWD
  cd /tmp
  go run `go env GOROOT`/src/crypto/tls/generate_cert.go --host=acme.certman-support.svc.cluster.local,acme.certman-support.svc,acme,localhost --ecdsa-curve=P256
  cd $current_dir
  mv /tmp/cert.pem ${SOURCE_PATH}/dev/pebble-cert.pem
  mv /tmp/key.pem ${SOURCE_PATH}/dev/pebble-key.pem
}

kubectl get ns certman-support  >/dev/null 2>&1 || kubectl create ns certman-support
if [ ! -f ${SOURCE_PATH}/dev/pebble-cert.pem ]; then
  create_certificate
fi

cat  << EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: pebble-cert
  namespace: certman-support
  labels:
    app.kubernetes.io/name: pebble
type: kubernetes.io/tls
data:
  tls.crt: $(cat ${SOURCE_PATH}/dev/pebble-cert.pem | base64 -w0)
  tls.key: $(cat ${SOURCE_PATH}/dev/pebble-key.pem | base64 -w0)
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: pebble-config
  namespace: certman-support
  labels:
    app.kubernetes.io/name: pebble
data:
  pebble-config.json: |
    {
       "pebble": {
          "certificate": "/etc/pebble/cert/tls.crt",
          "privateKey": "/etc/pebble/cert/tls.key",
          "listenAddress": ":8443",
          "managementListenAddress": ":8444",
          "certificateValidityPeriod": $PEBBLE_CERTIFICATE_VALIDITY
       },
       "va": {
          "dnsPort": 8053,
          "httpPort": 8056,
          "tlsPort": 8057,
          "resolver": "127.0.0.1:8053"
       }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pebble
  namespace: certman-support
  labels:
    app.kubernetes.io/name: pebble
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: pebble
  template:
    metadata:
      labels:
        app.kubernetes.io/name: pebble
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: pebble
          image: $PEBBLE_IMAGE
          volumeMounts:
            - name: pebble-config
              mountPath: /etc/pebble/config
            - name: pebble-cert
              mountPath: /etc/pebble/cert
          args:
            - -config
            - /etc/pebble/config/pebble-config.json
            - --dnsserver
            - 127.0.0.1:8053
          env:
            ## ref: https://github.com/letsencrypt/pebble#testing-at-full-speed
            - name: PEBBLE_VA_NOSLEEP
              value: "1"
          ports:
            - name: acme
              containerPort: 8443
            - name: acme-mgmt
              containerPort: 8444
          startupProbe:
            periodSeconds: 1
            httpGet:
              path: /dir
              port: acme
              scheme: HTTPS
        - name: pebble-challtestsrv
          image: $CHALLSRV_IMAGE
          args:
            - -defaultIPv6
            - ""
            - -defaultIPv4
            - 127.0.0.1
            - -dnsserver
            - :8053
            - -http01
            - :8056
            - -tlsalpn01
            - :8057
            - -management
            - :8055
          ports:
            - name: dns-udp
              containerPort: 8053
              protocol: UDP
            - name: dns-tcp
              containerPort: 8053
              protocol: TCP
            - name: http-01
              containerPort: 8056
            - name: tlsalpn01
              containerPort: 8057
            - name: mgmt
              containerPort: 8055
      volumes:
        - name: pebble-config
          configMap:
            name: pebble-config
        - name: pebble-cert
          secret:
            secretName: pebble-cert
---
apiVersion: v1
kind: Service
metadata:
  name: acme
  namespace: certman-support
  labels:
    app.kubernetes.io/name: pebble
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: pebble
  ports:
    - name: acme
      targetPort: acme
      port: 443
      nodePort: 30443
    - name: acme-alternative
      targetPort: acme
      port: 5443
---
apiVersion: v1
kind: Service
metadata:
  name: acme-mgmt
  namespace: certman-support
  labels:
    app.kubernetes.io/name: pebble
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: pebble
  ports:
    - name: acme-mgmt
      targetPort: acme-mgmt
      port: 8444
      nodePort: 30444
---
apiVersion: v1
kind: Service
metadata:
  name: pebble-challtestsrv
  namespace: certman-support
  labels:
    app.kubernetes.io/name: pebble
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: pebble
  ports:
    - name: dns-tcp
      targetPort: dns-tcp
      port: 8053
      protocol: TCP
    - name: dns-udp
      targetPort: dns-udp
      port: 8053
      protocol: UDP
    - name: http-01
      targetPort: http-01
      port: 8056
    - name: tlsalpn01
      targetPort: tlsalpn01
      port: 8057
    - name: mgmt
      targetPort: mgmt
      port: 8055
EOF