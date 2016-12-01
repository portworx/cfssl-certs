# ssl-gen.sh -- generate certs and keys for clustered services

This script generates a series of certs and keys based on a parameter file.

That file contains a string of IP addresses and DNS names which define each machine in the "cluster" of machines.  Each line is a peer of the cluster, with it's own individual cert and key.  All the certs, plus the certificate authority, are bundled together to create a bundled CRT file.  The name of the parameter file is the "Common Name" (i.e. the CN of the cert) used to generate the cluster's certs and keys. It is also used as the root for a numerical sequence when generating peer certs and keys.

The config file a comma-separated list of values, without any spaces.
```
hostname,<external-DNS>,<AWS-internal-DNS>,<AWS-internal-ip>,<AWS-external-IP>
e.g.
server01,server01.example.com,ip-ii-ii-ii-iii.region.compute.internal,ii.ii.ii.iii,eee.eee.eee.eee
```
where the first entry on a line is the external DNS address of the machine.  This is used as the server name (without the canonical part of the FQDN) when generating the certs.


# SETTING UP CERT KEYS

```
./ssl-gen.sh

generate SSL certs for etcd or consul using config file

    Usage: ssl-gen.sh -dhn <CONFIG_FILE>

    where

    -h  this help function
    -n  dry-run (don't generate certs but loop through config file)
```



Uses https://github.com/cloudflare/cfssl (Cloud Flare's ssl generator) to generate keys.  Generates a key for each host *tied* to both public and private AWS IP addresses.

It creates the following files (csr files generated are deleted by the script)
```
<config>-ca-key.pem - CA cert private key (DO NOT put on system)
<config>-ca.pem     - CA cert
service1.pem        - service1's cert (line 1 in config file)
service1-key.pem    - service1's cert private key
...
serviceN.pem        - serviceN's cert (line N in config file)
serviceN-key.pem    - serviceN's cert private key
<config>.crt        - combination of all the server PEMs+CA
```

You can check the validity with openssl.

```
openssl x509 -in <config>-ca.pem -text -noout
openssl x509 -in *.pem -text -noout
openssl x509 -in <config>.crt -text -noout
openssl rsa -in *-key.pem -check
```

Copy these files to /etc/ssl/<SERVICE> and set their permissions.

```
mkdir -p /etc/ssl/<SERVICE>
/bin/cp *.pem /etc/ssl/<SERVICE>
chmod 600 /etc/ssl/<SERVICE>/*key.*
chown -R <SERVICE>:<SERVICE> /etc/ssl/<SERVICE>
ls -l /etc/ssl/<SERVICE>
```

Then add update your service's config files to use the new certs and keys

Provided are dummy config files for a 3-node etcd cluster and a single node consul node, all running in AWS.

# ENVIRONMENT VARIABLES

etcdv2 uses the following environment variables to run etcdctl without specifying the certs on the command-line:

```
export ETCDCTL_CERT_FILE=/etc/ssl/etcd/cert.pem
export ETCDCTL_KEY_FILE=/etc/ssl/etcd/cert.key
export ETCDCTL_CA_FILE=/etc/ssl/etcd/ca.pem
```

etcdv3 uses different environment variables to run etcdctl without specifying the certs on the command-line if you specify ETCDCTL_API=3:

```
export ETCDCTL_API=3
export ETCDCTL_CACERT=/etc/ssl/etcd/ca.pem
export ETCDCTL_CERT=/etc/ssl/etcd/cert.pem
export ETCDCTL_KEY=/etc/ssl/etcd/cert.key
```

If you run with API=2, the old environment variables are used.

