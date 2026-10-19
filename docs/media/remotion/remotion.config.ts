import { Config } from '@remotion/cli/config';

// Recorded frames and their JSON timelines come from `scripts/readme_media.sh` (see ../README.md),
// written to docs/media/.out (gitignored).
Config.setPublicDir('../.out');
Config.setVideoImageFormat('png');
