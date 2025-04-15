#!/bin/bash
  
key="etherlinks"


function dnc_code(){
    mac=`echo $num1 | openssl aes-128-cbc -d -k $key -base64 -pbkdf2 -iter 100`
}

function enc_code(){
    num2=`echo $mac |openssl des3 -k $key -base64 -pbkdf2 -iter 100`
}

read -p "请填入机器码: " num1
dnc_code
enc_code
echo "该客户 MAC 地址是: $mac"
echo "该客户激活码是: $num2"
