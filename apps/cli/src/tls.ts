import { checkServerIdentity as checkHostname, type PeerCertificate } from "node:tls";

export function checkServerIdentity(hostname: string, certificate: PeerCertificate): Error | undefined {
  const issuer = certificate.issuer.CN;
  if (typeof issuer === "string" && /^EM (?:DV TLS|OV TLS|EV TLS|OV CS) CA - G3[BC]$/.test(issuer)) {
    return Object.assign(new Error("TLS certificate issued by a compromised eMudhra CA"), { code: "CERT_REVOKED" });
  }
  return checkHostname(hostname, certificate);
}
