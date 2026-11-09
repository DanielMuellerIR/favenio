"""Gemeinsame Grenzen der isolierten Linux-Bilddecoder."""

# Glycin-Lader brauchen auch bei kleinen Bildern mehr virtuellen Adressraum.
DECODER_ADDRESS_SPACE_BYTES = 1536 * 1024**2
