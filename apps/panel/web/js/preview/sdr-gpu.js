/* WebGL2 SDR presentation of C++-rendered linear P3 preview planes. */
const VERTEX = `#version 300 es
in vec2 position; out vec2 uv;
void main(){ gl_Position=vec4(position,0,1); uv=vec2((position.x+1.0)*.5,(1.0-position.y)*.5); }`;
const FRAGMENT = `#version 300 es
precision highp float; uniform sampler2D baseTexture; uniform sampler2D hdrTexture;
uniform float original; in vec2 uv; out vec4 color;
vec3 encode(vec3 v){ v=max(v,vec3(0)); return mix(1.055*pow(v,vec3(1.0/2.4))-0.055,12.92*v,lessThanEqual(v,vec3(.0031308))); }
float shoulder(float v){ return v<=.8?v:.8+.2*(1.0-exp(-(v-.8)/.2)); }
void main(){ vec3 v=original>.5?texture(baseTexture,uv).rgb:texture(hdrTexture,uv).rgb;
  if(original<.5) v=vec3(shoulder(v.r),shoulder(v.g),shoulder(v.b)); color=vec4(encode(v),1); }`;
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
  const textures=[gl.createTexture(),gl.createTexture()];
  for(const texture of textures){gl.bindTexture(gl.TEXTURE_2D,texture);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,floatFilter);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,floatFilter);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);}
  gl.useProgram(program); const position=gl.getAttribLocation(program,"position"); gl.enableVertexAttribArray(position);
  gl.bindBuffer(gl.ARRAY_BUFFER,buffer);gl.vertexAttribPointer(position,2,gl.FLOAT,false,0,0);
  gl.uniform1i(gl.getUniformLocation(program,"baseTexture"),0);gl.uniform1i(gl.getUniformLocation(program,"hdrTexture"),1);
  const original=gl.getUniformLocation(program,"original");
  return { kind:"sdr-gpu",
    upload(frame){ [frame.base,frame.hdr].forEach((plane,index)=>{gl.activeTexture(gl.TEXTURE0+index);gl.bindTexture(gl.TEXTURE_2D,textures[index]);
      gl.texImage2D(gl.TEXTURE_2D,0,gl.RGB32F,frame.width,frame.height,0,gl.RGB,gl.FLOAT,plane);}); gl.viewport(0,0,canvas.width,canvas.height); },
    uploadGainMap(){}, draw(_table,params){gl.useProgram(program);gl.uniform1f(original,params.original?1:0);gl.drawArrays(gl.TRIANGLES,0,6);},
    destroy(){canvas.removeEventListener("webglcontextlost",lost);textures.forEach(t=>gl.deleteTexture(t));gl.deleteBuffer(buffer);gl.deleteProgram(program);}
  };
}
