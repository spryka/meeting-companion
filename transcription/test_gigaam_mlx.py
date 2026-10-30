"""Synthetic contract tests; no models, Metal, or network required."""
import os
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch
import numpy as np
from gigaam_mlx_backend import TimestampedGigaAM, decode_with_frames, load_model
from transcribe import gigaam_words


class MLXTests(unittest.TestCase):
    def test_preparation_uses_pinned_albo_model(self):
        from model_assets import MODELS
        self.assertEqual(MODELS['gigaam']['repo'], 'al-bo/gigaam-v3-e2e-rnnt-mlx')
        self.assertEqual(MODELS['gigaam']['revision'], '9488b39159c6d30f0fbaef1e41459f1e078daf30')
        self.assertEqual(set(MODELS['gigaam']['files']), {'model.safetensors','config.json','tokenizer.model'})

    def setUp(self):
        self.mx = SimpleNamespace(array=np.array, expand_dims=np.expand_dims,
                                  argmax=np.argmax, eval=lambda *a: None)
        self.modules = {"mlx": SimpleNamespace(core=self.mx), "mlx.core": self.mx}

    def decode(self, labels, length, max_symbols=10):
        labels=iter(labels)
        decoder=SimpleNamespace(predict=lambda label,state,**kw:(None,None))
        def joint(f,g):
            k=next(labels)
            k=3 if k==0 else k-1
            return np.array([[[[int(i==k) for i in range(4)]]]])
        model=SimpleNamespace(head=SimpleNamespace(decoder=decoder,joint=joint),
            cfg=SimpleNamespace(vocabulary=["a","b","c"],rnnt_max_symbols=max_symbols))
        with patch.dict(sys.modules,self.modules):
            return decode_with_frames(model,np.zeros((length,2)),length)

    def test_emission_frames_include_blanks_and_multiple_symbols(self):
        self.assertEqual(self.decode([0,1,2,0,0,3,0],4),([0,1,2],[1,1,3]))
        self.assertEqual(self.decode([0,0],2),([],[]))
        self.assertEqual(self.decode([],0),([],[]))
        self.assertEqual(self.decode([1,2,3,0],2,2),([0,1,2],[0,0,1]))

    def model(self, vocabulary):
        class Model:
            cfg=SimpleNamespace(sample_rate=16000,win_length=320,hop_length=160,
                subsampling_factor=4,vocabulary=vocabulary)
            def _compute_features(self,samples): return None,None
            def __call__(self,*args): return np.zeros((1,3,2)),[3]
            def _decode_tokens(self,ids): return "Не знаю"
        return Model()

    def test_timestamped_result_reuses_word_joining_and_seams(self):
        with patch.dict(sys.modules,self.modules), patch("gigaam_mlx_backend.decode_with_frames",
                return_value=([0,1,2],[0,10,11])):
            result=TimestampedGigaAM(self.model(["▁Не","▁зна","ю"])).recognize(np.zeros(16000),sample_rate=16000)
        self.assertEqual(result.timestamps,[0,.4,.44])
        self.assertEqual(result.text,"Не знаю")
        words=gigaam_words(result,24,25,24,24.5)
        self.assertEqual([w["text"] for w in words],["Не","знаю"])
        self.assertEqual(words[1]["start"],24.4)
        self.assertEqual(gigaam_words(result,24,25,24.5,25),[])

    def test_invalid_empty_and_short_audio(self):
        adapter=TimestampedGigaAM(self.model([]))
        with patch.dict(sys.modules,self.modules):
            self.assertEqual(adapter.recognize(np.zeros(0),sample_rate=16000).tokens,[])
            for samples,rate in ((np.zeros(10),48000),(np.zeros((2,10)),16000),(np.array([np.nan]),16000)):
                with self.assertRaises(ValueError): adapter.recognize(samples,sample_rate=rate)
            with patch("gigaam_mlx_backend.decode_with_frames",return_value=([],[])):
                self.assertEqual(adapter.recognize(np.zeros(10),sample_rate=16000).tokens,[])

    def test_loading_uses_shared_preparation_and_respects_offline(self):
        calls=[]
        model=self.model([])
        modules={"gigaam_mlx_runtime": SimpleNamespace(load_model=lambda path:model)}
        with patch.dict(sys.modules,modules),patch.dict(os.environ,{"HF_HUB_OFFLINE":"1"}), \
             patch("model_assets.model_path",side_effect=lambda *a,**kw:calls.append((a,kw)) or "/cached"):
            self.assertIs(load_model().model,model)
        self.assertEqual(calls,[(('gigaam',),{'download':False})])
        with patch.dict(sys.modules,modules),patch.dict(os.environ,{"HF_HUB_OFFLINE":"1"}), \
             patch("model_assets.model_path",side_effect=RuntimeError("not cached")):
            with self.assertRaisesRegex(RuntimeError,"not cached"): load_model()


if __name__ == "__main__": unittest.main()
