# Shared desktop platform layer

This directory owns shared SDL3 desktop behavior. Controller discovery,
mapping, hot-plug polling, axes, triggers, and button edges live here so every
desktop build consumes the same gamepad contract. The portable desktop audio
bridge will also live here when the remaining native audio implementations are
consolidated.
