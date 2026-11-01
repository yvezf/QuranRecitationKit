"""Optional local model test of the C ABI; no audio or model is downloaded."""
import ctypes as c, os, json, sys
lib=c.CDLL(os.environ['QRK_LIBRARY'])
lib.qrk_version.restype=c.c_char_p
lib.qrk_last_error.restype=c.c_char_p
lib.qrk_recognizer_new.argtypes=[c.c_char_p,c.c_char_p,c.c_char_p,c.POINTER(c.c_void_p)]
lib.qrk_set_expected.argtypes=[c.c_void_p,c.c_char_p]
callback_type=c.CFUNCTYPE(None,c.c_char_p,c.c_void_p)
lib.qrk_feed.argtypes=[c.c_void_p,c.POINTER(c.c_float),c.c_size_t,callback_type,c.c_void_p]
lib.qrk_stop.argtypes=[c.c_void_p,c.POINTER(c.c_void_p)]
lib.qrk_string_free.argtypes=[c.c_void_p];lib.qrk_free.argtypes=[c.c_void_p]
handle=c.c_void_p();assert lib.qrk_recognizer_new(os.fsencode(os.environ['QRK_MODEL_DIR']),None,None,c.byref(handle))==0,lib.qrk_last_error()
try:
 assert lib.qrk_set_expected(handle,b'{"surah":112}')==0,lib.qrk_last_error()
 events=[]
 @callback_type
 def receive(data,user):events.append(json.loads(data))
 pcm=(c.c_float*8000)()
 assert lib.qrk_feed(handle,pcm,len(pcm),receive,None)==0,lib.qrk_last_error()
 summary=c.c_void_p();assert lib.qrk_stop(handle,c.byref(summary))==0,lib.qrk_last_error()
 try:result=json.loads(c.string_at(summary))
 finally:lib.qrk_string_free(summary)
 assert result['type']=='summary' and result['verses']==[]
 assert any(e.get('reason')=='noise' for e in result['events'])
 print(json.dumps({'abi':lib.qrk_version().decode(),'events':events,'summary':result}))
finally:lib.qrk_free(handle)
