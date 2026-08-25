BaseOS for the Miyoo Flip
https://github.com/apommel/baseos-my355

This card boots the device. It is not the frontend card.

Put NextUI on a second SD card and insert it in the LEFT slot. BaseOS finds it
and starts it automatically; this card stays untouched.

Advanced: one card can do both. Unzip a NextUI release onto this volume and
leave the left slot empty. A card in the left slot that carries a frontend
still takes precedence.

Keep mtd5-original-*.img if it is here. It is the copy of your device's
original preloader, and the way back to a fully stock device.
