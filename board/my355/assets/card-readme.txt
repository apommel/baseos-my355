FlipBase for the Miyoo Flip
https://github.com/apommel/FlipBase

This card boots the device. It is not the frontend card.

Put NextUI on a second SD card and insert it in the LEFT slot. FlipBase finds it
and starts it automatically; this card stays untouched.

Advanced: one card can do both. Unzip a NextUI release onto this volume and
leave the left slot empty. A card in the left slot that carries a frontend
still takes precedence.

Keep mtd5-original-*.img if it is here. It is the copy of your device's
original preloader, and the way back to a fully stock device.

Settings, such as the device's network name and SSH password, go in
flipbase.conf on this volume. See INSTALL.md#settings on the page above.
