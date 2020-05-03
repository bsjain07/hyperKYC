#!/bin/bash
#
# Copyright IBM Corp All Rights Reserved
#
# SPDX-License-Identifier: Apache-2.0
#
# Exit on first error
set -ex

# don't rewrite paths for Windows Git Bash users
export MSYS_NO_PATHCONV=1
starttime=$(date +%s)
CC_SRC_LANGUAGE=${1:-"go"}
CC_SRC_LANGUAGE=`echo "$CC_SRC_LANGUAGE" | tr [:upper:] [:lower:]`
if [ "$CC_SRC_LANGUAGE" = "go" -o "$CC_SRC_LANGUAGE" = "golang"  ]; then
	CC_RUNTIME_LANGUAGE=golang
	CC_SRC_PATH=github.com/hyperledger/fabric-samples/chaincode/kycDetails/go
	echo Vendoring Go dependencies ...
	pushd ../chaincode/kycDetails/go
	GO111MODULE=on go mod vendor
	popd
	echo Finished vendoring Go dependencies
elif [ "$CC_SRC_LANGUAGE" = "java" ]; then
	CC_RUNTIME_LANGUAGE=java
	CC_SRC_PATH=/opt/gopath/src/github.com/hyperledger/fabric-samples/chaincode/kycDetails/java/build/install/fabcar
  echo Compiling Java code ...
  pushd ../chaincode/kycDetails/java
  ./gradlew installDist
  popd
  echo Finished compiling Java code
elif [ "$CC_SRC_LANGUAGE" = "javascript" ]; then
	CC_RUNTIME_LANGUAGE=node # chaincode runtime language is node.js
	CC_SRC_PATH=/opt/gopath/src/github.com/hyperledger/fabric-samples/chaincode/kycDetails/javascript
elif [ "$CC_SRC_LANGUAGE" = "typescript" ]; then
	CC_RUNTIME_LANGUAGE=node # chaincode runtime language is node.js
	CC_SRC_PATH=/opt/gopath/src/github.com/hyperledger/fabric-samples/chaincode/kycDetails/typescript
	echo Compiling TypeScript code into JavaScript ...
	pushd ../chaincode/kycDetails/typescript
	npm install
	npm run build
	popd
	echo Finished compiling TypeScript code into JavaScript
else
	echo The chaincode language ${CC_SRC_LANGUAGE} is not supported by this script
	echo Supported chaincode languages are: go, java, javascript, and typescript
	exit 1
fi


# clean the keystore
rm -rf ./hfc-key-store

# launch network; create channel and join peer to channel
pushd ./kyc-network
echo y | ./byfn.sh down
echo y | ./byfn.sh up -a -n -s couchdb
popd

CONFIG_ROOT=/opt/gopath/src/github.com/hyperledger/fabric/peer
ORG1_MSPCONFIGPATH=${CONFIG_ROOT}/crypto/peerOrganizations/citiBank.kyc.com/users/Admin@citiBank.kyc.com/msp
ORG1_TLS_ROOTCERT_FILE=${CONFIG_ROOT}/crypto/peerOrganizations/citiBank.kyc.com/peers/peer0.citiBank.kyc.com/tls/ca.crt
ORG2_MSPCONFIGPATH=${CONFIG_ROOT}/crypto/peerOrganizations/sbi.kyc.com/users/Admin@sbi.kyc.com/msp
ORG2_TLS_ROOTCERT_FILE=${CONFIG_ROOT}/crypto/peerOrganizations/sbi.kyc.com/peers/peer0.sbi.kyc.com/tls/ca.crt
ORDERER_TLS_ROOTCERT_FILE=${CONFIG_ROOT}/crypto/ordererOrganizations/kyc.com/orderers/orderer.kyc.com/msp/tlscacerts/tlsca.kyc.com-cert.pem

PEER0_ORG1="docker exec
-e CORE_PEER_LOCALMSPID=CitiBankMSP
-e CORE_PEER_ADDRESS=peer0.citiBank.kyc.com:7051
-e CORE_PEER_MSPCONFIGPATH=${ORG1_MSPCONFIGPATH}
-e CORE_PEER_TLS_ROOTCERT_FILE=${ORG1_TLS_ROOTCERT_FILE}
cli
peer
--tls=true
--cafile=${ORDERER_TLS_ROOTCERT_FILE}
--orderer=orderer.kyc.com:7050"

PEER1_ORG1="docker exec
-e CORE_PEER_LOCALMSPID=CitiBankMSP
-e CORE_PEER_ADDRESS=peer1.citiBank.kyc.com:8051
-e CORE_PEER_MSPCONFIGPATH=${ORG1_MSPCONFIGPATH}
-e CORE_PEER_TLS_ROOTCERT_FILE=${ORG1_TLS_ROOTCERT_FILE}
cli
peer
--tls=true
--cafile=${ORDERER_TLS_ROOTCERT_FILE}
--orderer=orderer.kyc.com:7050"

PEER0_ORG2="docker exec
-e CORE_PEER_LOCALMSPID=SbiMSP
-e CORE_PEER_ADDRESS=peer0.sbi.kyc.com:9051
-e CORE_PEER_MSPCONFIGPATH=${ORG2_MSPCONFIGPATH}
-e CORE_PEER_TLS_ROOTCERT_FILE=${ORG2_TLS_ROOTCERT_FILE}
cli
peer
--tls=true
--cafile=${ORDERER_TLS_ROOTCERT_FILE}
--orderer=orderer.kyc.com:7050"

PEER1_ORG2="docker exec
-e CORE_PEER_LOCALMSPID=SbiMSP
-e CORE_PEER_ADDRESS=peer1.sbi.kyc.com:10051
-e CORE_PEER_MSPCONFIGPATH=${ORG2_MSPCONFIGPATH}
-e CORE_PEER_TLS_ROOTCERT_FILE=${ORG2_TLS_ROOTCERT_FILE}
cli
peer
--tls=true
--cafile=${ORDERER_TLS_ROOTCERT_FILE}
--orderer=orderer.kyc.com:7050"

echo "Packaging smart contract on peer0.citiBank.kyc.com"
${PEER0_ORG1} lifecycle chaincode package \
  kycDetails.tar.gz \
  --path "$CC_SRC_PATH" \
  --lang "$CC_RUNTIME_LANGUAGE" \
  --label kycv1

echo "Installing smart contract on peer0.citiBank.kyc.com"
${PEER0_ORG1} lifecycle chaincode install \
  kycDetails.tar.gz

echo "Installing smart contract on peer1.citiBank.kyc.com"
${PEER1_ORG1} lifecycle chaincode install \
  kycDetails.tar.gz

echo "Determining package ID for smart contract on peer0.citiBank.kyc.com"
REGEX='Package ID: (.*), Label: kycv1'
if [[ `${PEER0_ORG1} lifecycle chaincode queryinstalled` =~ $REGEX ]]; then
  PACKAGE_ID_ORG1=${BASH_REMATCH[1]}
else
  echo Could not find package ID for kycv1 chaincode on peer0.citiBank.kyc.com
  exit 1
fi

echo "Approving smart contract for org1"
${PEER0_ORG1} lifecycle chaincode approveformyorg \
  --package-id ${PACKAGE_ID_ORG1} \
  --channelID mychannel \
  --name kycDetails \
  --version 1.0 \
  --signature-policy "AND('CitiBankMSP.member','SbiMSP.member')" \
  --sequence 1 \
  --waitForEvent

echo "Packaging smart contract on peer0.sbi.kyc.com"
${PEER0_ORG2} lifecycle chaincode package \
  kycDetails.tar.gz \
  --path "$CC_SRC_PATH" \
  --lang "$CC_RUNTIME_LANGUAGE" \
  --label kycv1

echo "Installing smart contract on peer0.sbi.kyc.com"
${PEER0_ORG2} lifecycle chaincode install kycDetails.tar.gz

echo "Installing smart contract on peer1.sbi.kyc.com"
${PEER1_ORG2} lifecycle chaincode install kycDetails.tar.gz

echo "Determining package ID for smart contract on peer0.sbi.kyc.com"
REGEX='Package ID: (.*), Label: kycv1'
if [[ `${PEER0_ORG2} lifecycle chaincode queryinstalled` =~ $REGEX ]]; then
  PACKAGE_ID_ORG2=${BASH_REMATCH[1]}
else
  echo Could not find package ID for kycv1 chaincode on peer0.sbi.kyc.com
  exit 1
fi

echo "Approving smart contract for org2"
${PEER0_ORG2} lifecycle chaincode approveformyorg \
  --package-id ${PACKAGE_ID_ORG2} \
  --channelID mychannel \
  --name kycDetails \
  --version 1.0 \
  --signature-policy "AND('CitiBankMSP.member','SbiMSP.member')" \
  --sequence 1 \
  --waitForEvent

echo "Committing smart contract"
${PEER0_ORG1} lifecycle chaincode commit \
  --channelID mychannel \
  --name kycDetails \
  --version 1.0 \
  --signature-policy "AND('CitiBankMSP.member','SbiMSP.member')" \
  --sequence 1 \
  --waitForEvent \
  --peerAddresses peer0.citiBank.kyc.com:7051 \
  --peerAddresses peer0.sbi.kyc.com:9051 \
  --tlsRootCertFiles ${ORG1_TLS_ROOTCERT_FILE} \
  --tlsRootCertFiles ${ORG2_TLS_ROOTCERT_FILE}

echo "Submitting initLedger transaction to smart contract on mychannel"
# echo "The transaction is sent to all of the peers so that chaincode is built before receiving the following requests"
${PEER0_ORG1} chaincode uploadKYC \
  -C mychannel \
  -n kycDetails \
  -c '{"function":"initLedger","Args":[]}' \
  --waitForEvent \
  --waitForEventTimeout 300s \
  --peerAddresses peer0.citiBank.kyc.com:7051 \
  --peerAddresses peer0.sbi.kyc.com:9051 \
  --tlsRootCertFiles ${ORG1_TLS_ROOTCERT_FILE} \
  --tlsRootCertFiles ${ORG2_TLS_ROOTCERT_FILE}

# Temporary workaround (see FAB-15897) - cannot invoke across all four peers at the same time, so use a query to build
# the chaincode across the remaining peers.
# ${PEER1_ORG1} chaincode query \
#   -C mychannel \
#   -n kycDetails \
#   -c '{"function":"queryAllKyc","Args":[]}' \
#   --peerAddresses peer1.citiBank.kyc.com:8051 \
#   --tlsRootCertFiles ${ORG1_TLS_ROOTCERT_FILE}
# ${PEER1_ORG2} chaincode query \
#   -C mychannel \
#   -n kycDetails \
#   -c '{"function":"queryAllKyc","Args":[]}' \
#   --peerAddresses peer1.sbi.kyc.com:10051 \
#   --tlsRootCertFiles ${ORG2_TLS_ROOTCERT_FILE}

cat <<EOF

Total setup execution time : $(($(date +%s) - starttime)) secs ...

Next, use the FabCar applications to interact with the deployed FabCar contract.
The FabCar applications are available in multiple programming languages.
Follow the instructions for the programming language of your choice:

JavaScript:

  Start by changing into the "javascript" directory:
    cd javascript

  Next, install all required packages:
    npm install

  Then run the following applications to enroll the admin user, and register a new user
  called user1 which will be used by the other applications to interact with the deployed
  FabCar contract:
    node enrollAdmin
    node registerUser

  You can run the invoke application as follows. By default, the invoke application will
  create a new car, but you can update the application to submit other transactions:
    node invoke

  You can run the query application as follows. By default, the query application will
  return all cars, but you can update the application to evaluate other transactions:
    node query

TypeScript:

  Start by changing into the "typescript" directory:
    cd typescript

  Next, install all required packages:
    npm install

  Next, compile the TypeScript code into JavaScript:
    npm run build

  Then run the following applications to enroll the admin user, and register a new user
  called user1 which will be used by the other applications to interact with the deployed
  FabCar contract:
    node dist/enrollAdmin
    node dist/registerUser

  You can run the invoke application as follows. By default, the invoke application will
  create a new car, but you can update the application to submit other transactions:
    node dist/invoke

  You can run the query application as follows. By default, the query application will
  return all cars, but you can update the application to evaluate other transactions:
    node dist/query

Java:

  Start by changing into the "java" directory:
    cd java

  Then, install dependencies and run the test using:
    mvn test

  The test will invoke the sample client app which perform the following:
    - Enroll admin and user1 and import them into the wallet (if they don't already exist there)
    - Submit a transaction to create a new car
    - Evaluate a transaction (query) to return details of this car
    - Submit a transaction to change the owner of this car
    - Evaluate a transaction (query) to return the updated details of this car

EOF