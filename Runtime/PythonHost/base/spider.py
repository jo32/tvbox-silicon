"""The CatVod Python spider base class that TVBox subscriptions import as `base.spider`.

Method names and defaults follow the TVBox pyramid contract so existing spiders run unmodified.
The host (`host.py`) installs the proxy URL, cache file, and module loader through `_runtime`.
"""
import base64
import hashlib
import json
import os
import re
import time
from abc import ABCMeta
from importlib.machinery import SourceFileLoader

import requests


class _Runtime:
    proxy_url = 'http://127.0.0.1:-1/proxy?do=py'
    cache_file = None
    load_module = None


_runtime = _Runtime()


def _read_cache():
    try:
        with open(_runtime.cache_file, encoding='utf-8') as stream:
            return json.load(stream)
    except (OSError, TypeError, ValueError):
        return {}


def _write_cache(values):
    if not _runtime.cache_file:
        return
    temporary = _runtime.cache_file + '.tmp'
    with open(temporary, 'w', encoding='utf-8') as stream:
        json.dump(values, stream, ensure_ascii=False)
    os.replace(temporary, _runtime.cache_file)


class Spider(metaclass=ABCMeta):
    def __init__(self):
        self.extend = ''

    def init(self, extend=''):
        pass

    def homeContent(self, filter):
        return {}

    def homeVideoContent(self):
        return {}

    def categoryContent(self, tid, pg, filter, extend):
        return {}

    def detailContent(self, ids):
        return {}

    def searchContent(self, key, quick, pg='1'):
        return {}

    def searchContentPage(self, key, quick, pg):
        return self.searchContent(key, quick, pg)

    def playerContent(self, flag, id, vipFlags):
        return {}

    def liveContent(self, url):
        return ''

    def localProxy(self, param):
        return [404, 'text/plain', '']

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return ''

    def destroy(self):
        pass

    def getName(self):
        return ''

    def getDependence(self):
        return []

    def setExtendInfo(self, extend):
        self.extend = extend

    def loadSpider(self, name):
        return self.loadModule(name).Spider()

    def loadModule(self, name):
        if _runtime.load_module:
            return _runtime.load_module(name)
        path = os.path.join('..', 'plugin', name + '.py')
        return SourceFileLoader(name, path).load_module()

    def regStr(self, reg, src, group=1):
        match = re.search(reg, src)
        return match.group(group) if match else ''

    def removeHtmlTags(self, src):
        return re.sub('<.*?>', '', src)

    def cleanText(self, src):
        return re.sub('[\U0001F600-\U0001F64F\U0001F300-\U0001F5FF\U0001F680-\U0001F6FF\U0001F1E0-\U0001F1FF]', '', src)

    def fetch(self, url, params=None, cookies=None, headers=None, timeout=5, verify=True, stream=False, allow_redirects=True):
        response = requests.get(url, params=params, cookies=cookies, headers=headers, timeout=timeout,
                                verify=verify, stream=stream, allow_redirects=allow_redirects)
        response.encoding = 'utf-8'
        return response

    def post(self, url, params=None, data=None, json=None, cookies=None, headers=None, timeout=5, verify=True, stream=False, allow_redirects=True):
        response = requests.post(url, params=params, data=data, json=json, cookies=cookies, headers=headers, timeout=timeout,
                                 verify=verify, stream=stream, allow_redirects=allow_redirects)
        response.encoding = 'utf-8'
        return response

    def html(self, content):
        from lxml import etree
        return etree.HTML(content)

    def str2json(self, text):
        return json.loads(text)

    def json2str(self, value):
        return json.dumps(value, ensure_ascii=False)

    def e64(self, text):
        return base64.b64encode(str(text).encode('utf-8')).decode('utf-8')

    def d64(self, text):
        return base64.b64decode(str(text).encode('utf-8')).decode('utf-8')

    def md5(self, text):
        return hashlib.md5(str(text).encode('utf-8')).hexdigest()

    def getProxyUrl(self, local=True):
        return _runtime.proxy_url

    def log(self, message):
        print(json.dumps(message, ensure_ascii=False) if isinstance(message, (dict, list)) else message, flush=True)

    def getCache(self, key):
        value = _read_cache().get(key)
        if isinstance(value, dict) and 'expiresAt' in value and value['expiresAt'] < int(time.time()):
            self.delCache(key)
            return None
        return value

    def setCache(self, key, value):
        values = _read_cache()
        values[key] = str(value) if isinstance(value, (int, float)) else value
        _write_cache(values)
        return 'succeed'

    def delCache(self, key):
        values = _read_cache()
        values.pop(key, None)
        _write_cache(values)
        return 'succeed'
