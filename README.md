Introduction
-----------------

This branch implements ivrcall.
ivrcall let's user invokes a REST api to call a number and play a IVR message to him/her.
ivrcall can be used to implement so-called "voice validation code"(vvc), which is a supplement of "SMS validation code".

API 
-----

    POST /v1/accounts/<account id>/users/<user id>/ivrcall/number
    
    {"data": 
      {
        "IVRName": "play_validation_code",
        "Text": "8888",
        "cid-number": "051288888888",
        "cid-name": "jxiewei",
      }
    }


Customize your ivr
---------------------

IVR flow is implemented as freeswitch "phrase", it can be customized easily.
There're many examples under /etc/kazoo/freeswitch/lang/en/ivr/. You can copy and modify it easily.
Once you defined a new ivr, you can specify it in API's "IVRName" parameter to play it.


