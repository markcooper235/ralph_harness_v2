#!/bin/bash

# Test the security pattern matching
content="some generic task do some generic work that doesn't match any keywords do something generic"
echo "Content: $content"

if echo "$content" | rg -q "(security|vulnerability|vulnerabilities|exploit|exploits|patch|patching|auth|authentication|authorization|encrypt|encryption|decrypt|decryption|token|tokens|oauth|password|passwords|secret|secrets|key|keys|cert|certificate|ssl|tls|xss|csrf|injection|sql injection|xxe|rce|privilege|escalation|audit|auditing|compliance)"; then
  echo "MATCHED SECURITY PATTERN"
else
  echo "DID NOT MATCH SECURITY PATTERN"
fi

# Test with authentication
content2="Document user authentication endpoints"
echo "Content2: $content2"

if echo "$content2" | rg -q "(security|vulnerability|vulnerabilities|exploit|exploits|patch|patching|auth|authentication|authorization|encrypt|encryption|decrypt|decryption|token|tokens|oauth|password|passwords|secret|secrets|key|keys|cert|certificate|ssl|tls|xss|csrf|injection|sql injection|xxe|rce|privilege|escalation|audit|auditing|compliance)"; then
  echo "MATCHED SECURITY PATTERN"
else
  echo "DID NOT MATCH SECURITY PATTERN"
fi

# Test what exactly matched
echo "$content2" | rg -o "(security|vulnerability|vulnerabilities|exploit|exploits|patch|patching|auth|authentication|authorization|encrypt|encryption|decrypt|decryption|token|tokens|oauth|password|passwords|secret|secrets|key|keys|cert|certificate|ssl|tls|xss|csrf|injection|sql injection|xxe|rce|privilege|escalation|audit|auditing|compliance)" || echo "No match"
