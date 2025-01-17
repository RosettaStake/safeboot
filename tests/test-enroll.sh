#!/bin/bash

set -euo pipefail

if [[ $0 = /* ]]; then
	TOP=${0%/*}
elif [[ $0 = */* ]]; then
	TOP=$PWD/${0%/*}
else
	TOP=$PWD
fi

TOP=${TOP%/*}

# shellcheck source=functions.sh
. "$TOP/functions.sh"

#PATH=$TOP/sbin:$TOP/swtpm/src/swtpm:$PATH

d=
success=false
swtpmpids=()
cleanup() {
	set +euo pipefail
	if $success; then
		echo Success
	else
		echo FAIL
	fi
	exec 2>/dev/null
	for pid in "${swtpmpids[@]}"; do
		kill -9 "$pid"
	done
	[[ -n $d ]] && rm -rf "$d"
}
trap cleanup EXIT
d=$(mktemp -d)
cd "$d"
mkdir db

# Configure enrollment options
mkdir escrowpubs
cat > db/tofu_pcrs <<EOF
 - 0
 - 1
EOF

cat > "${d}/attest-enroll.conf" <<EOF
DBDIR=${d}/db
POLICY=7fdad037a921f7eec4f97c08722692028e96888f0b970dc7b3bb6a9c97e8f988
ESCROW_POLICY=
TRANSPORT_METHOD=EK
GENPROGS+=(gentest0)
ESCROW_PUBS_DIR=${d}/escrowpubs
POLICIES[rootfskey]=pcr11
POLICIES[test0]=pcr11
EOF

policy_pcr11_unext=(tpm2 policypcr '--pcr-list=sha256:11')

declare -A TCTIs
start_port=9880
start_swtpm() {
	local tries=0

	while ((tries < 3)) && lsof -i ":${start_port}" >/dev/null; do
		((++tries))
		((++start_port))
	done
	local port=$start_port
	((++start_port))

	while ((tries < 3)) && lsof -i ":${start_port}" >/dev/null; do
		((++tries))
		((++start_port))
	done
	local cport=$((start_port))
	((++start_port))

	# There's no support in tpm2-tss / tpm2-tools for AF_LOCAL sockets for
	# the swtpm TCTI.  There's no support in `swtpm socket` for allocating
	# port numbers.
	#
	# We try our best.
	mkdir "${d}/tpm$port"
	swtpm socket						\
		--tpm2						\
		--tpmstate dir="${d}/tpm$port"			\
		--server type="tcp,bindaddr=0.0.0.0,port=$port"	\
		--ctrl type="tcp,bindaddr=0.0.0.0,port=$cport"	\
		--flags startup-clear				&
	swtpmpids+=($!)
	TCTIs[$1]="swtpm:host=localhost,port=$port"
}

make_escrow() {
	echo "Making an escrow agent and key"
	start_swtpm "$1"
	TPM2TOOLS_TCTI="${TCTIs[$1]}"			\
	tpm2 createek					\
		--ek-context /dev/null			\
		--public "${d}/escrowpubs/${1}.pub"
}

make_client() {
	local ekpub
	local dir

	echo "Making client $1"
	mkdir "${d}/$1"
	start_swtpm "$1"
	echo "SWTPM for $1: ${TCTIs[$1]}"
	echo "Getting EK for $1"
	TPM2TOOLS_TCTI="${TCTIs[$1]}"		\
	tpm2 createek				\
		--ek-context "${d}/${1}/ek.ctx"	\
		--public "${d}/${1}/ek.pub"
	TPM2TOOLS_TCTI="${TCTIs[$1]}"			\
	tpm2 readpublic					\
		--object-context "${d}/${1}/ek.ctx"	\
		--format PEM				\
		--output "${d}/${1}/ek.pem"

	echo "Enrolling $1"
	(
		(($# == 1)) || unset TPM2TOOLS_TCTI
		attest-enroll -C "${d}/attest-enroll.conf" "$1" < "${d}/${1}/ek.pub"
	)

	echo "Checking that PEM also works"
	if attest-enroll -C "${d}/attest-enroll.conf" "$1" < "${d}/${1}/ek.pem"; then
		die "Using PEM we got a different TPM2B_PUBLIC!"
	fi

	ekpub=$(cat "${d}/db/hostname2ekpub/$1")
	dir="${d}/db/${ekpub:0:2}/${ekpub}"

	# Check that the client can recover the secret
	echo "Checking that $1 can recover its secrets"
	echo TPM2TOOLS_TCTI="${TCTIs[$1]}"
	echo tpm2-recv "${dir}/test0.symkeyenc" "${d}/symkey" "${policy_pcr11_unext[@]}"
	TPM2TOOLS_TCTI="${TCTIs[$1]}"	\
	tpm2-recv 	"${dir}/test0.symkeyenc"	\
			"${d}/symkey"			\
			"${policy_pcr11_unext[@]}"

	sleep 1
	aead_decrypt	"${dir}/test0.enc"		\
			"${d}/symkey"			\
			"${d}/pt"
	sha256 < "${d}/pt" > "${d}/digest"
	cmp "${d}/db/${ekpub:0:2}/${ekpub}/test0pub" "${d}/digest"
	rm -f "${d}/symkey" "${d}/pt" "${d}/digest"

	# Check that we can recover the secret
	echo "Checking that the escrow key can recover ${1}'s secrets"
	sleep 1
	TPM2TOOLS_TCTI="${TCTIs[BreakGlass]}"	\
	tpm2-recv	"${dir}/escrow-BreakGlass.pub-test0.symkeyenc"	\
			"${d}/symkey"
	aead_decrypt	"${dir}/test0.enc"				\
			"${d}/symkey"					\
			"${d}/pt"
	sha256 < "${d}/pt" > "${d}/digest"
	cmp "${d}/db/${ekpub:0:2}/${ekpub}/test0pub" "${d}/digest"
	rm -f "${d}/symkey" "${d}/pt" "${d}/digest"
}

# Make a TPM for this script itself -- needed for operations that should be
# possible to implement in software only but which either tpm2-tools doesn't
# (yet) or which we're not yet using.
echo "Starting an SWTPM for things that should be software-only (but aren't yet)"
start_swtpm _self_
export TPM2TOOLS_TCTI="${TCTIs[_self_]}"

make_escrow BreakGlass
make_client foo no-tpm
make_client bar
make_client baz
for i in foo bar baz; do
	ekpub=$(cat "${d}/db/hostname2ekpub/$i")
	dir="${d}/db/${ekpub:0:2}/${ekpub}"
	for k in foo bar baz; do
		[[ $i = "$k" ]] && continue
		echo "Checking that $i can't read ${k}'s secrets"
		rm -f "${d}/symkey"
		TPM2TOOLS_TCTI="${TCTIs[$k]}" \
		tpm2-recv	"${dir}/test0.symkeyenc"	\
				"${d}/symkey" 2>/dev/null	\
				"${policy_pcr11_unext[@]}"	\
		&& die "Whoops!  $i _can_ read ${k}'s secrets!!"
		rm -f "${d}/symkey"
	done
done

# Now test initramfs bootscript:
echo "Checking that initramfs bootscript works (direct, no attestation)"
for i in foo bar baz; do
	echo "	Checking that initramfs bootscript works for $i"
	ekpub=$(cat "${d}/db/hostname2ekpub/$i")
	dir="${d}/db/${ekpub:0:2}/${ekpub}"
	echo "Checking $i (${TCTIs[$i]}) ($dir)"
	tar -C "$dir" -cf - . \
	| TPM2TOOLS_TCTI="${TCTIs[$i]}"		\
	  BOOTSCRIPT_TEST=1			\
	  "$TOP/initramfs/bootscript"
done

# Now test attestation without an HTTP server, but using all the relevant code
# paths.  If this works then everything should work with a server as well.
echo "Checking that initramfs bootscript works (direct attestation)"
for i in foo bar baz; do
	echo "	Checking that initramfs bootscript works for $i"
	ekpub=$(cat "${d}/db/hostname2ekpub/$i")
	dir="${d}/db/${ekpub:0:2}/${ekpub}"
	echo "Checking $i (${TCTIs[$i]}) ($dir)"

	# Client part (would be POST request body to attestation end-point):
	#
	#	tpm2-attest quote
	#
	# Server part to consume the POST request body and create the POST
	# response body:
	#
	#	tpm2-attest verify | attest-verify verify | tpm2-attest seal
	#
	# then the client part to consume that POST response body:
	#
	#	tpm2-attest unseal
	#
	# and then the initramfs bootscript to further unseal the long-term
	# secrets:

	TPM2TOOLS_TCTI="${TCTIs[$i]}" \
	"$TOP/sbin/tpm2-attest" quote > "${d}/quote.tar"

	# The quote file has to be be a file because sealing refers to it.

	"$TOP/sbin/tpm2-attest" verify "${d}/quote.tar"			\
	| SAFEBOOT_DB_DIR="${d}/db"					\
	  /safeboot/sbin/attest-verify verify True			\
	| "$TOP/sbin/tpm2-attest" seal "${d}/quote.tar"			\
	| TPM2TOOLS_TCTI="${TCTIs[$i]}"					\
	  "$TOP/sbin/tpm2-attest" unseal				\
	| TPM2TOOLS_TCTI="${TCTIs[$i]}"					\
	  BOOTSCRIPT_TEST=1						\
	  "$TOP/initramfs/bootscript"

	# The tpm2-attest seal | tpm2-attest unseal bit here provides transport
	# security, essentially.
	#
	# The real "pipe" is from attest-enroll to the bootscript.
	#
	# Note that only attest-verify needs access to the enrolled clients
	# attestation database (SAFEBOOT_DB_DIR).
done
success=true
