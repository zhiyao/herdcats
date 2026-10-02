import React from 'react';
import {AbsoluteFill, Img, Still, registerRoot, staticFile, useVideoConfig} from 'remotion';

// Marketing geometry is defined in a 1284 x 2778 reference canvas.
// Palette and typography follow DESIGN.md; this is a decorative device shell,
// not an Apple-supplied hardware render. The screenshot itself is never stretched.
const theme = {
  canvas: '#0A0B0E',
  ink: '#FFFFFF',
  cyan: '#0EDCD5',
  font: '"SF Pro Display", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif',
};

function Phone({source, sourceWidth, sourceHeight, width, left, top, rotation = 0, tablet = false}) {
  const bezel = width * 0.018;
  const screenWidth = width - bezel * 2;
  const screenHeight = screenWidth * sourceHeight / sourceWidth;
  const radius = width * (tablet ? 0.035 : 0.115);
  return <div style={{
    position: 'absolute',
    left,
    top,
    width,
    transform: `rotate(${rotation}deg)`,
    transformOrigin: '50% 20%',
    height: screenHeight + bezel * 2,
    padding: bezel,
    boxSizing: 'border-box',
    borderRadius: radius,
    background: 'linear-gradient(135deg, #4A4D54 0%, #1E2024 15%, #383B42 45%, #18191C 75%, #42454D 100%)',
    boxShadow: '0 40px 90px rgba(0, 0, 0, 0.85), 0 12px 30px rgba(0, 0, 0, 0.6), 0 0 1px 1px rgba(255, 255, 255, 0.08), 0 0 60px rgba(14, 220, 213, 0.06)',
  }}>
    <div style={{
      position: 'relative',
      width: screenWidth,
      height: screenHeight,
      overflow: 'hidden',
      borderRadius: radius - bezel,
      background: '#000000',
      outline: `${width * 0.005}px solid #14161A`,
    }}>
      <Img src={staticFile(source)} style={{display: 'block', width: screenWidth, height: screenHeight}} />
      {/* Simulator captures omit the physical Dynamic Island. */}
      {!tablet && <div style={{
        position: 'absolute',
        top: screenWidth * 0.029,
        left: '37%',
        width: '26%',
        height: screenWidth * 0.075,
        borderRadius: 100,
        background: '#000000',
      }} />}
    </div>
  </div>;
}

function Artwork({slide, sourceWidth, sourceHeight, secondarySize, family = 'iphone', background = theme.canvas}) {
  const {width, height} = useVideoConfig();
  const tablet = family === 'ipad';
  const scale = Math.min(width / (tablet ? 2064 : 1284), height / (tablet ? 2752 : 2778));
  const canvasWidth = width / scale;
  const canvasHeight = height / scale;
  const closeup = slide.layout === 'closeup';
  const tilted = slide.layout === 'tilted';
  const phoneWidth = tablet ? (closeup ? 1980 : 1540) : (closeup ? 1170 : 970);
  const screenHeight = (phoneWidth * 0.964) * sourceHeight / sourceWidth;
  const phoneTop = tablet
    ? (closeup ? 420 : 560)
    : closeup ? 620 : Math.min(tilted ? 540 : 590, canvasHeight - screenHeight - (tilted ? 180 : 110));
  const phoneLeft = (canvasWidth - phoneWidth) / 2 + (tilted && !tablet ? -48 : 0);
  return <AbsoluteFill style={{background, overflow: 'hidden'}}>
    {/* Subtle ambient cyan glow in the background behind device */}
    <div style={{
      position: 'absolute',
      width: '100%',
      height: '100%',
      background: 'radial-gradient(ellipse at 50% 65%, rgba(14, 220, 213, 0.04) 0%, rgba(0, 0, 0, 0) 70%)',
      pointerEvents: 'none',
    }} />
    <div style={{
      position: 'absolute',
      width: canvasWidth,
      height: canvasHeight,
      transform: `scale(${scale})`,
      transformOrigin: 'top left',
      fontFamily: theme.font,
      color: theme.ink,
    }}>
      <div style={{
        position: 'absolute',
        left: tablet ? 120 : 70,
        right: tablet ? 120 : 70,
        top: tablet ? 120 : 160,
        textAlign: 'center',
        fontSize: tablet ? 126 : 100,
        fontWeight: 750,
        letterSpacing: -3.5,
        lineHeight: 1.12,
      }}>
        <div>{slide.headline}</div>
        <div style={{color: theme.cyan, marginTop: 14}}>{slide.accent}</div>
      </div>
      {slide.layout === 'stacked' ? <>
        <Phone source={slide.source} sourceWidth={sourceWidth} sourceHeight={sourceHeight}
          tablet={tablet} width={tablet ? 1500 : 1030} left={tablet ? 40 : 80} top={tablet ? 530 : 580}
          rotation={tablet ? 3.5 : 6} />
        <Phone source={slide.secondarySource} sourceWidth={secondarySize.width} sourceHeight={secondarySize.height}
          tablet={tablet} width={tablet ? 1460 : 1030} left={tablet ? 540 : 270} top={tablet ? 1140 : 1470}
          rotation={tablet ? -6 : -7} />
      </> : <Phone source={slide.source} sourceWidth={sourceWidth} sourceHeight={sourceHeight}
        tablet={tablet} width={phoneWidth} left={phoneLeft} top={phoneTop}
        rotation={tilted ? (tablet ? -3 : -4) : 0} />}
    </div>
  </AbsoluteFill>;
}

function Root() {
  return <Still id="AppStoreScreenshot" component={Artwork} width={1284} height={2778}
    defaultProps={{
      slide: {
        source: 'iphone/03_spaces.png',
        headline: 'Orchestrate spaces,',
        accent: 'all from your pocket.',
        layout: 'device',
      },
      sourceWidth: 1320,
      sourceHeight: 2868,
      width: 1284,
      height: 2778,
      family: 'iphone',
      background: theme.canvas,
    }}
    calculateMetadata={({props}) => ({width: props.width, height: props.height})} />;
}

registerRoot(Root);
