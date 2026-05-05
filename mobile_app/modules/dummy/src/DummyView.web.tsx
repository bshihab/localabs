import * as React from 'react';

import { DummyViewProps } from './Dummy.types';

export default function DummyView(props: DummyViewProps) {
  return (
    <div>
      <iframe
        style={{ flex: 1 }}
        src={props.url}
        onLoad={() => props.onLoad({ nativeEvent: { url: props.url } })}
      />
    </div>
  );
}
