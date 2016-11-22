#!/bin/bash
# generate certs for etcd or consul using CloudFlare's cfssl [201611.22MeV]
# https://www.digitalocean.com/community/tutorials/how-to-secure-your-coreos-cluster-with-tls-ssl-and-firewall-rules
# https://github.com/cloudflare/cfssl

# config file is in the form
# DNS name, internal AWS DNS, internal AWS IP, external AWS IP

if [ "`echo $PATH | grep /usr/local/bin`" == "" ]; then PATH=$PATH:/usr/local/bin; fi

function USAGE {
	cat <<-EOFUSAGE

	generate SSL certs for etcd or consul using config file

    Usage: ${0##*/} -dhn <CONFIG_FILE>

    where

    -h  this help function
    -n  dry-run (don't generate certs but loop through config file)
EOFUSAGE
	exit 2
}

# parse arguments
OPT_d=1; OPT_n=1; QUIET="--quiet"
while getopts ":dhn" OPT; do
	case ${OPT} in

	d)  OPT_D=0      # DEBUG mode
		QUIET=""
		;;

	n)  OPT_n=0      # dry-run mode
		;;

	h|?) USAGE
		;;

	esac
done
shift $((OPTIND-1)) # move to next argument after options

[ $# -lt 1 ] && echo "?config filename missing" && USAGE
[ ! -e ${1} ] && echo "?config file missing" && USAGE

## defaults
#
conf_file=${1}
conf_base=${1##*/}
conf_name=${conf_base%%.*}
cur_d=$(pwd)

ca=${conf_name}-ca
ca_csr="/tmp/${ca}-csr.json"
ca_config="/tmp/${ca}-config.json"

# rsa/2048...ecdsa is a smaller key but takes 10x to encode/decode
key_algo=rsa
key_size=2048
cert_expire=`expr 5 \* 365 \* 24`	# hours in 5 years

C="US"
L="CA"
O="Example, Inc."
ST="Anytown"
OU="devops"

[ ! -e /usr/local/bin/ ] && mkdir -P /usr/local/bin
case $(uname) in
	Darwin)
		if [ ! -e  /usr/local/bin/cfssl ]; then
			curl -s -L -o /usr/local/bin/cfssl \
				https://pkg.cfssl.org/R1.2/cfssl_darwin-amd64
		fi
		if [ ! -e  /usr/local/bin/cfssljson ]; then
			curl -s -L -o /usr/local/bin/cfssljson \
				https://pkg.cfssl.org/R1.2/cfssljson_darwin-amd64
		fi
		if [ ! -e  /usr/local/bin/mkbundle ]; then
			curl -s -L -o /usr/local/bin/mkbundle \
				https://pkg.cfssl.org/R1.2/mkbundle_darwin-amd64
		fi
		;;
	Linux)
		if [ ! -e  /usr/local/bin/cfssl ]; then
			curl -s -L -o /usr/local/bin/cfssl \
				https://pkg.cfssl.org/R1.2/cfssl_linux-amd64
		fi
		if [ ! -e  /usr/local/bin/cfssljson ]; then
			curl -s -L -o /usr/local/bin/cfssljson \
				https://pkg.cfssl.org/R1.2/cfssljson_linux-amd64
		fi
		if [ ! -e  /usr/local/bin/mkbundle ]; then
			curl -s -L -o /usr/local/bin/mkbundle \
				https://pkg.cfssl.org/R1.2/mkbundle_linux-amd64
		fi
		;;
	*)
		echo "OS $(uname) not supported"
		exit 2
		;;
esac
chmod +x /usr/local/bin/{cfssl,cfssljson,mkbundle}

[ ! -e ${conf_name} ] && mkdir -p ${conf_name}
/bin/cp ${conf_file} ${conf_name}/
cd ${conf_name}

[ $OPT_n -eq 1 ] && cat <<-EOFCACONFIG > ${ca_config}
	{
		"signing": {
			"default": {
				"expiry": "${cert_expire}h"
			},
			"profiles": {
				"server": {
					"expiry": "${cert_expire}h",
					"usages": [
						"signing",
						"key encipherment",
						"server auth"
					]
				},
				"client": {
					"expiry": "${cert_expire}h",
					"usages": [
						"signing",
						"key encipherment",
						"client auth"
					]
				},
				"client-server": {
					"expiry": "${cert_expire}h",
					"usages": [
						"signing",
						"key encipherment",
						"server auth",
						"client auth"
					]
				}
			}
		}
	}
EOFCACONFIG

[ $OPT_n -eq 1 ] && cat <<-EOFCACSR > ${ca_csr}
	{
		"CN": "${conf_name}",
		"hosts": [ 
		],
		"key": {
			"algo": "${key_algo}",
			"size": ${key_size} 
		},
		"names": [
			{
				"C": "${C}",
				"L": "${L}",
				"O": "${O}",
				"ST": "${ST}",
				"OU": "${OU}"
			}
		]
	}
EOFCACSR

echo "================================================== generating self-signed CA cert+key"
if [ ${OPT_n} -eq 1 ]; then
    cfssl genkey -initca=true ${ca_csr} | cfssljson -bare ${ca}
    openssl verify -purpose sslserver -CAfile ${ca}.pem ${ca}.pem
fi

# these certs work for connecting between nodes [201608.25MeV]
# this code works for using the ca_csr above or in-line
# works for etcdctl if you use server cert, key, and CA key.

# config file is in the form
# DNS name, internal AWS DNS, internal AWS IP, external AWS IP
for host in $(cat ${conf_file}) ; do
	h=$(echo ${host} | sed -e 's/,/","/g' -e 's/^/"/' -e 's/$/"/')
	s=$(echo ${host} | awk -F"," '{print $1}' | sed -e 's/.portworx.com//')
    # CN must match CN of CA key
	f=$(printf '{"CN":"%s","hosts":[%s],"key":{"algo":"%s","size":%s}}' ${conf_name} ${h} ${key_algo} ${key_size})
	echo "================================================== generating ${s} certs+keys"
	if [ $OPT_n -eq 1 ]; then
	    echo ${f} | cfssl gencert -ca=${ca}.pem -ca-key=${ca}-key.pem -config=${ca_config} \
		    -hostname="${h}" -profile=client-server - | cfssljson -bare ${s}
	    openssl verify -purpose sslserver -CAfile ${ca}.pem ${s}.pem
	fi
done

rm -f ${ca_csr}* ${ca_config}* *.csr ${conf_file}
echo "================================================== bundling all certs"
if [ $OPT_n -eq 1 ]; then
    mkbundle .
    mv cert-bundle.crt ${conf_name}.crt
    openssl x509 -in ${conf_name}.crt -text -noout
fi

[ "$(ls *.pem)" != "" ] && chmod 644 *.pem
cd ${cur_d}
exit
