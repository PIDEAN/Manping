import { Composition, staticFile } from 'remotion';
import { Scene, type SceneProps } from './Scene';
import { build, FPS, H, W, type SceneData } from './timeline';

/** One composition per README animation; ids match the director's scenes (DemoDirector.swift) and ../scenes.json. */
export const SCENES = [
  { id: 'hero', title: '首页到播放' },
  { id: 'danmaku', title: '弹幕' },
  { id: 'mini', title: '小窗' },
  { id: 'live', title: '直播' },
  { id: 'settings', title: '设置与致谢' },
  // A hand-made timeline over still screenshots, for checking the composition and the encoder offline.
  { id: 'test', title: '合成测试' },
] as const;

export function Root() {
  return (
    <>
      {SCENES.map((s) => (
        <Composition
          key={s.id}
          id={s.id}
          component={Scene}
          width={W}
          height={H}
          fps={FPS}
          durationInFrames={FPS}
          defaultProps={{ scene: s.id, title: s.title, data: null } satisfies SceneProps}
          calculateMetadata={async ({ props }) => {
            const data = (await fetch(staticFile(`${props.scene}.json`)).then((r) => r.json())) as SceneData;
            data.title ??= props.title;
            return { durationInFrames: Math.ceil((build(data).total / 1000) * FPS), props: { ...props, data } };
          }}
        />
      ))}
    </>
  );
}
