#!/bin/bash

# Simulate what _determine_agent_from_story does for content extraction

title="Some generic task"
description="Do some generic work that doesn't match any keywords"
tasks_content="Do something generic"

# Convert to lowercase as done in the function
title_lc=$(echo "$title" | tr '[:upper:]' '[:lower:]')
description_lc=$(echo "$description" | tr '[:upper:]' '[:lower:]')
tasks_content_lc=$(echo "$tasks_content" | tr '[:upper:]' '[:lower:]')

content="$title_lc $description_lc $tasks_content_lc"
echo "Content: '$content'"

# Check each pattern
echo "Checking security pattern:"
if echo "$content" | rg -q "(security|vulnerability|vulnerabilities|exploit|exploits|patch|patching|auth|authentication|authorization|encrypt|encryption|decrypt|decryption|token|tokens|oauth|password|passwords|secret|secrets|key|keys|cert|certificate|ssl|tls|xss|csrf|injection|sql injection|xxe|rce|privilege|escalation|audit|auditing|compliance)"; then
  echo "  MATCHED"
  echo "$content" | rg -o "(security|vulnerability|vulnerabilities|exploit|exploits|patch|patching|auth|authentication|authorization|encrypt|encryption|decrypt|decryption|token|tokens|oauth|password|passwords|secret|secrets|key|keys|cert|certificate|ssl|tls|xss|csrf|injection|sql injection|xxe|rce|privilege|escalation|audit|auditing|compliance)"
else
  echo "  NOT MATCHED"
fi

echo "Checking documentation pattern:"
if echo "$content" | rg -q "(doc|documentation|comment|comments|explain|explanation|description|descriptions|readme|readmes|guide|guides|tutorial|tutorials|walkthrough|faq|faqs|wiki|wikis|markdown|md)"; then
  echo "  MATCHED"
  echo "$content" | rg -o "(doc|documentation|comment|comments|explain|explanation|description|descriptions|readme|readmes|guide|guides|tutorial|tutorials|walkthrough|faq|faqs|wiki|wikis|markdown|md)"
else
  echo "  NOT MATCHED"
fi
