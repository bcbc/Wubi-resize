md5sum wubi-resize.sh verify.sh > MD5SUMS
gpg --local-user openbcbc@gmail.com --output MD5SUMS.gpg --armor --detach-sign  MD5SUMS
sha256sum wubi-resize.sh verify.sh > SHA256SUMS
gpg --local-user openbcbc@gmail.com --output SHA256SUMS.gpg --armor --detach-sign  SHA256SUMS
