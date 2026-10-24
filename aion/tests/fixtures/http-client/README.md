# Test certificate for aion/http-client

`pinned-test.crt` and `pinned-test.key` are a self-signed certificate and its private key for
the made-up name `pinned.test`, used only by `aion/tests/http-client.lisp`. A TLS server in the
test image presents them on 127.0.0.1, and the client trusts `pinned-test.crt` through
`ca-path`. The tests use them to show that a connection pinned to 127.0.0.1 still verifies the
certificate against the URL's host name. The key protects nothing. It is committed so that the
test needs no generation step, and it is valid until 2126.

Made with:

    openssl req -x509 -newkey rsa:2048 -nodes -keyout pinned-test.key -out pinned-test.crt \
      -days 36500 -subj "/CN=pinned.test" -addext "subjectAltName=DNS:pinned.test"

`ip-test.crt` and `ip-test.key` are the same kind of pair for the addresses 127.0.0.1 and ::1
(#915). Their only subject alternative names are those two IP addresses, and the common name is
`ip.test`. The tests use them to show that a request to `https://[::1]/` sends no SNI name and
verifies the certificate against `::1`, the address without the URL's brackets. Also valid until
2126.

Made with:

    openssl req -x509 -newkey rsa:2048 -nodes -keyout ip-test.key -out ip-test.crt \
      -days 36500 -subj "/CN=ip.test" -addext "subjectAltName=IP:127.0.0.1,IP:::1"
