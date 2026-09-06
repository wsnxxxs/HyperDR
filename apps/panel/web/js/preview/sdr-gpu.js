/* WebGL2 SDR presentation of C++-rendered linear P3 preview planes. */
const VERTEX = `#version 300 es
in vec2 position; out vec2 uv;
void main(){ gl_Position=vec4(position,0,1); uv=vec2((position.x+1.0)*.5,(1.0-position.y)*.5); }`;
const FRAGMENT = `#version 300 es
precision highp float; uniform sampler2D baseTexture;
in vec2 uv; out vec4 color;
vec3 encode(vec3 v){ v=max(v,vec3(0)); return mix(1.055*pow(v,vec3(1.0/2.4))-0.055,12.92*v,lessThanEqual(v,vec3(.0031308))); }
void main(){
  ivec2 bs=textureSize(baseTexture,0); ivec2 xy=clamp(ivec2(uv*vec2(bs)),ivec2(0),bs-1);
  color=vec4(encode(texelFetch(baseTexture,xy,0).rgb),1);
}`;
function compile(gl,type,source){ const s=gl.createShader(type); gl.shaderSource(s,source); gl.compileShader(s);
  if(!gl.getShaderParameter(s,gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s)); return s; }

export function createSdrGpuRenderer(canvas, onContextLost) {
  const lost=(event)=>{event.preventDefault();onContextLost?.();};
  canvas.addEventListener("webglcontextlost",lost,{once:true});
  const gl=canvas.getContext("webgl2",{alpha:false,antialias:false});
  if(!gl) throw new Error("WebGL2 unavailable");
  if ("drawingBufferColorSpace" in gl) gl.drawingBufferColorSpace = "display-p3";
  const floatFilter = gl.getExtension("OES_texture_float_linear") ? gl.LINEAR : gl.NEAREST;
  const program=gl.createProgram(), vs=compile(gl,gl.VERTEX_SHADER,VERTEX), fs=compile(gl,gl.FRAGMENT_SHADER,FRAGMENT);
  gl.attachShader(program,vs);gl.attachShader(program,fs);gl.linkProgram(program);gl.deleteShader(vs);gl.deleteShader(fs);
  if(!gl.getProgramParameter(program,gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
  const buffer=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,buffer);
  gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([-1,-1,1,-1,-1,1,-1,1,1,-1,1,1]),gl.STATIC_DRAW);
  const textures=[gl.createTexture()];
  for(const texture of textures){gl.bindTexture(gl.TEXTURE_2D,texture);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,floatFilter);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,floatFilter);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);}
  gl.useProgram(program); const position=gl.getAttribLocation(program,"position"); gl.enableVertexAttribArray(position);
  gl.bindBuffer(gl.ARRAY_BUFFER,buffer);gl.vertexAttribPointer(position,2,gl.FLOAT,false,0,0);
  gl.uniform1i(gl.getUniformLocation(program,"baseTexture"),0);
  let previous = null;
  return { kind:"sdr-gpu",
    upload(frame){
      if(!(frame.metadata?.baseId && previous?.metadata?.baseId===frame.metadata.baseId
          && previous.width===frame.width && previous.height===frame.height)) {
        gl.activeTexture(gl.TEXTURE0);gl.bindTexture(gl.TEXTURE_2D,textures[0]);
        gl.texImage2D(gl.TEXTURE_2D,0,gl.RGB32F,frame.width,frame.height,0,gl.RGB,gl.FLOAT,frame.base);
      }
      previous=frame; gl.viewport(0,0,canvas.width,canvas.height); },
    uploadGainMap(){}, draw(){gl.useProgram(program);gl.drawArrays(gl.TRIANGLES,0,6);},
    destroy(){canvas.removeEventListener("webglcontextlost",lost);textures.forEach(t=>gl.deleteTexture(t));gl.deleteBuffer(buffer);gl.deleteProgram(program);}
  };
}
