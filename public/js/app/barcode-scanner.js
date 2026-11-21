(function () {
    // ZXing (WebAssembly) barcode decoder — used when the phone has no built-in BarcodeDetector (e.g. iPhone)
    const PONYFILL_URL = 'https://fastly.jsdelivr.net/npm/barcode-detector@3/dist/iife/ponyfill.min.js';
    // Only a camera the crew chose with 🔄 is kept (board 52). The old key also held cameras the
    // scanner jumped to by itself (sometimes the front camera): it is forgotten.
    const CAMERA_KEY = 'ds-scanner-camera-chosen';
    try { localStorage.removeItem('bb-scanner-camera'); } catch (e) {}
    const isFront = (label) => /front|user|selfie|facetime/i.test(String(label || ''));

    const scripts = {};
    function loadScript(src) {
        if (!scripts[src]) {
            scripts[src] = new Promise((resolve, reject) => {
                const s = document.createElement('script');
                s.src = src;
                s.async = true;
                s.onload = () => resolve();
                s.onerror = () => {
                    delete scripts[src];
                    reject(new Error('Could not load the barcode decoder. Check your internet connection.'));
                };
                document.head.appendChild(s);
            });
        }
        return scripts[src];
    }

    const detectors = {};
    async function createDetector(formats) {
        const key = formats.join(',');
        if (detectors[key]) return detectors[key];

        let detector = null;

        // Android Chrome: use the fast built-in detector when it supports all formats
        if ('BarcodeDetector' in window) {
            try {
                const supported = await window.BarcodeDetector.getSupportedFormats();
                if (formats.every((f) => supported.includes(f))) {
                    detector = new window.BarcodeDetector({ formats });
                }
            } catch (e) {}
        }

        // iPhone / others: ZXing WebAssembly
        if (!detector) {
            await loadScript(PONYFILL_URL);
            detector = new window.BarcodeDetectionAPI.BarcodeDetector({ formats });
        }

        detectors[key] = detector;
        return detector;
    }

    let audioCtx = null;
    function beep() {
        try {
            audioCtx = audioCtx || new (window.AudioContext || window.webkitAudioContext)();
            const osc = audioCtx.createOscillator();
            const gain = audioCtx.createGain();
            osc.type = 'square';
            osc.frequency.value = 1200;
            gain.gain.value = 0.08;
            osc.connect(gain);
            gain.connect(audioCtx.destination);
            osc.start();
            osc.stop(audioCtx.currentTime + 0.12);
        } catch (e) {}
    }

    function describeError(e) {
        const name = (e && e.name) || '';
        const msg = String((e && (e.message || e)) || '');
        if (name === 'NotAllowedError' || /permission|notallowed/i.test(msg))
            return 'Camera permission was denied. Allow camera access for this site in your browser settings, then try again.';
        if (name === 'NotFoundError' || /requested device not found/i.test(msg))
            return 'No camera was found on this device.';
        if (name === 'NotReadableError' || /could not start|in use/i.test(msg))
            return 'The camera is being used by another app. Close it and try again.';
        return msg || 'Unable to start the camera.';
    }

    function waitForVideo(video, timeout = 4000) {
        return new Promise((resolve) => {
            if (video.videoWidth > 0) return resolve();
            const done = () => { clearTimeout(t); video.removeEventListener('loadedmetadata', done); resolve(); };
            const t = setTimeout(done, timeout);
            video.addEventListener('loadedmetadata', done);
        });
    }

    // A tiny copy of the picture, to notice when the camera only sends black frames
    const probe = document.createElement('canvas');
    probe.width = 32;
    probe.height = 18;
    const probeCtx = probe.getContext('2d', { willReadFrequently: true });

    function brightness(video) {
        try {
            probeCtx.drawImage(video, 0, 0, probe.width, probe.height);
            const px = probeCtx.getImageData(0, 0, probe.width, probe.height).data;
            let sum = 0;
            for (let i = 0; i < px.length; i += 4) sum += px[i] + px[i + 1] + px[i + 2];
            return sum / (px.length / 4) / 3;
        } catch (e) {
            return 255; // cannot read the picture: do not complain
        }
    }

    const ios = /iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
    const homeScreenApp = window.matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
    const BLACK_TIP = 'The camera picture is black. Close other apps that use the camera, check that this site may use the camera, '
        + (ios && homeScreenApp ? 'or close the app fully and open it again. ' : 'or reload the page. ')
        + 'You can always type the code above.';

    const TORCH_KEY = 'ds-torch-at';
    const TORCH_KEEP = 10 * 60 * 1000; // the flashlight comes back on by itself within 10 minutes
    const VIDEO = { width: { ideal: 1280 }, height: { ideal: 720 } }; // light and fast; the frame is read in full detail

    /*
     * Start the camera while the trip is still opening (tap on a trip), so the scan screen
     * finds it running. Not used within 10 s: let go of it.
     */
    /*
     * Open a camera: the chosen one, else a back camera for sure ("exact"), else whatever the phone
     * calls the back camera (computers with one camera).
     */
    async function openStream(id) {
        const tries = id ? [{ ...VIDEO, deviceId: { exact: id } }] : [];
        tries.push({ ...VIDEO, facingMode: { exact: 'environment' } }, { ...VIDEO, facingMode: { ideal: 'environment' } });
        let last = null;
        for (const video of tries) {
            try {
                return await navigator.mediaDevices.getUserMedia({ audio: false, video });
            } catch (e) {
                if (e && e.name === 'NotAllowedError') throw e;
                last = e;
            }
        }
        throw last;
    }

    let warm = null;
    window.dsWarmCamera = function (formats) {
        try {
            if (formats) createDetector(formats.map((f) => String(f).toLowerCase())).catch(() => {});
            if (warm || !navigator.mediaDevices || !window.isSecureContext) return;
            let saved = null;
            try { saved = localStorage.getItem(CAMERA_KEY); } catch (e) {}
            const w = { stream: null, timer: null };
            warm = w;
            openStream(saved)
                .then((st) => { if (warm === w) { w.stream = st; w.timer = setTimeout(() => { if (warm === w) { st.getTracks().forEach((t) => t.stop()); warm = null; } }, 10000); } else st.getTracks().forEach((t) => t.stop()); })
                .catch(() => { if (warm === w) warm = null; });
        } catch (e) { warm = null; }
    };
    function takeWarm() {
        if (!warm || !warm.stream || !warm.stream.active) return null;
        clearTimeout(warm.timer);
        const st = warm.stream;
        warm = null;
        return st;
    }

    /*
     * Box photos sent in the back: the crew scans the next box while a photo uploads.
     * Each photo: shrunk on the phone, sent with its % shown, tried again 3 times.
     */
    let photoState = null;
    function photos() {
        if (!photoState) photoState = window.Alpine ? window.Alpine.reactive({ items: [] }) : { items: [] };
        return photoState;
    }
    function sendPhoto(item, tries = 0) {
        const fd = new FormData();
        fd.append('photo', item.file, 'photo.jpg');
        fd.append('invoice_id', item.invoiceId);
        if (item.condition) fd.append('condition', item.condition);
        if (item.note) fd.append('note', item.note);
        const xhr = new XMLHttpRequest();
        xhr.open('POST', item.url);
        const token = document.querySelector('meta[name="csrf-token"]');
        if (token) xhr.setRequestHeader('X-CSRF-TOKEN', token.content);
        xhr.setRequestHeader('Accept', 'application/json');
        xhr.upload.onprogress = (e) => { if (e.lengthComputable) item.p = Math.min(99, Math.round(e.loaded / e.total * 100)); };
        xhr.onload = () => {
            if (xhr.status >= 200 && xhr.status < 300) {
                try { item.serverId = JSON.parse(xhr.responseText).id; } catch (e) {}
                item.p = 100; item.done = true; item.failed = false; item.file = null;
            } else if (xhr.status >= 500 && tries < 3) setTimeout(() => sendPhoto(item, tries + 1), 2000 * (tries + 1));
            else { item.failed = true; try { item.why = JSON.parse(xhr.responseText).message; } catch (e) {} }
        };
        xhr.onerror = () => { if (tries < 3) setTimeout(() => sendPhoto(item, tries + 1), 2000 * (tries + 1)); else item.failed = true; };
        xhr.send(fd);
    }
    window.dsPhotos = {
        state: photos,
        async add(file, info) {
            const small = window.dsShrinkPhoto ? await window.dsShrinkPhoto(file) : file;
            const item = { id: Date.now() + Math.random(), invoiceId: info.invoiceId, code: info.code || '', condition: info.condition || null, note: info.note || null,
                url: info.url, file: small, thumb: URL.createObjectURL(small), p: 2, done: false, failed: false, serverId: null, why: null };
            photos().items.push(item);
            sendPhoto(photos().items[photos().items.length - 1]);
        },
        retry(item) { if (item.file) { item.failed = false; item.p = 2; sendPhoto(item); } },
        going() { return photos().items.filter((i) => !i.done && !i.failed); },
        saved() { return photos().items.filter((i) => i.done).length; },
        failed() { return photos().items.filter((i) => i.failed); },
        of(invoiceId) { return photos().items.filter((i) => String(i.invoiceId) === String(invoiceId)); },
    };

    window.barcodeScanner = function (config) {
        const formats = (config.formats && config.formats.length ? config.formats : ['code_128', 'qr_code'])
            .map((f) => String(f).toLowerCase());

        const canvas = document.createElement('canvas');
        const ctx = canvas.getContext('2d', { willReadFrequently: true });

        let stream = null;
        let detector = null;
        let session = 0;
        let loopTimer = null;
        let startTimer = null;
        let watchTimer = null;
        let observer = null;
        let onVisibilityChange = null;
        let darkSince = 0;
        let frame = 0;
        let tried = new Set();
        let onCommand = null;
        // The scanner's own box. Not this.$el: called from a button inside it, this.$el is that button,
        // and a button that hides itself (Camera off · tap to scan) made the camera stop again.
        let root = null;
        let pending = { code: null, n: 0, at: 0 }; // a read waits for the same read once more
        let unsureSince = 0;
        let activity = 0;
        let dimSince = 0;
        const confirmReads = Math.max(1, config.confirm || 1);
        const idleOff = config.idleOff || 0;
        const hardAfter = config.hardAfter || 3000;

        return {
            scanning: false,
            loading: false,
            error: null,
            hint: null,
            lastCode: null,
            lastAt: 0,
            manualCode: '',
            cameras: [],
            cameraId: null,
            autoCam: null,
            currentId: null,
            facing: 'back',
            camList: false,
            stoppedByUser: false,
            flash: false,
            torchSupported: false,
            torchOn: false,
            paused: false,
            hard: false,
            typing: false,
            typed: '',
            darkTip: false,
            offWhy: null,

            init() {
                root = this.$el;
                try { this.cameraId = localStorage.getItem(CAMERA_KEY) || null; } catch (e) {}

                onVisibilityChange = () => {
                    if (document.hidden) {
                        this.stop();
                    } else if (config.autoStart && !this.stoppedByUser && root.getClientRects().length) {
                        this.start();
                    }
                };
                document.addEventListener('visibilitychange', onVisibilityChange);

                // From the page: pause while a result is open, let go of the camera for the camera app
                onCommand = (e) => {
                    const d = (e && e.detail) || {};
                    if (d.release) { this.stop(); return; }
                    if ('paused' in d) this.setPaused(!!d.paused);
                };
                window.addEventListener('ds-scanner', onCommand);
                window.dsScanner = this;

                // Start when the scanner becomes visible (modal opened), stop when hidden (modal closed)
                if ('IntersectionObserver' in window) {
                    observer = new IntersectionObserver((entries) => {
                        const entry = entries[entries.length - 1];
                        entry.isIntersecting ? this.onShown() : this.onHidden();
                    }, { threshold: 0.01 });
                    observer.observe(root);
                } else if (config.autoStart) {
                    setTimeout(() => this.start(), 300);
                }
            },

            destroy() {
                document.removeEventListener('visibilitychange', onVisibilityChange);
                window.removeEventListener('ds-scanner', onCommand);
                if (window.dsScanner === this) window.dsScanner = null;
                if (observer) observer.disconnect();
                clearTimeout(startTimer);
                this.stop();
            },

            onShown() {
                this.stoppedByUser = false;
                if (!config.autoStart) return;
                clearTimeout(startTimer);
                startTimer = setTimeout(() => this.start(), config.startDelay ?? 300); // let the modal finish opening
            },

            onHidden() {
                clearTimeout(startTimer);
                this.stop();
            },

            async start(afterBlack = false) {
                if (this.scanning || this.loading) return;
                this.error = null;
                this.stoppedByUser = false;
                if (!afterBlack) {
                    tried = new Set();
                    this.autoCam = null; // a camera tried after a black picture is not kept
                    this.hint = null;
                }
                darkSince = 0;

                if (!window.isSecureContext) {
                    this.error = 'The camera only works over HTTPS (or on localhost). Open this page with https://';
                    return;
                }
                if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
                    this.error = 'This browser does not support camera access. Type the code instead.';
                    return;
                }

                const my = ++session;
                this.loading = true;

                try {
                    // Load the decoder at the same time as the camera starts
                    const detectorPromise = createDetector(formats);

                    const want = this.autoCam || this.cameraId;
                    let s = afterBlack || want ? null : takeWarm();
                    if (!s) s = await openStream(want);
                    try {
                        const set = s.getVideoTracks()[0].getSettings();
                        if (this.cameraId && set.deviceId && set.deviceId !== this.cameraId) this.forgetCamera(); // the chosen camera is gone
                    } catch (e) {}

                    if (my !== session) { s.getTracks().forEach((t) => t.stop()); return; }
                    stream = s;

                    // Attach the camera only once the preview box is on screen:
                    // iPhone home screen apps show a black picture otherwise.
                    await this.$nextTick();
                    await new Promise((resolve) => requestAnimationFrame(() => resolve()));

                    const video = this.$refs.video;
                    video.muted = true;
                    video.setAttribute('muted', '');
                    video.setAttribute('playsinline', '');
                    video.setAttribute('autoplay', '');
                    video.srcObject = stream;
                    try { await video.play(); } catch (e) {}
                    await waitForVideo(video);
                    if (video.paused) {
                        try { await video.play(); } catch (e) {}
                    }

                    const track = stream.getVideoTracks()[0];
                    try {
                        const set = track.getSettings();
                        this.currentId = set.deviceId || null;
                        this.facing = set.facingMode ? (set.facingMode === 'user' ? 'front' : 'back') : (isFront(track.label) ? 'front' : 'back');
                    } catch (e) { this.facing = isFront(track.label) ? 'front' : 'back'; }
                    try { await track.applyConstraints({ advanced: [{ focusMode: 'continuous' }] }); } catch (e) {}
                    try {
                        const caps = track.getCapabilities ? track.getCapabilities() : {};
                        this.torchSupported = !!caps.torch;
                    } catch (e) { this.torchSupported = false; }
                    this.torchOn = false;
                    let torchAt = 0;
                    try { torchAt = Number(localStorage.getItem(TORCH_KEY) || 0); } catch (e) {}
                    if (this.torchSupported && torchAt && Date.now() - torchAt < TORCH_KEEP) {
                        try { await track.applyConstraints({ advanced: [{ torch: true }] }); this.torchOn = true; } catch (e) {}
                    }

                    detector = await detectorPromise;
                    if (my !== session) return;

                    this.scanning = true;
                    this.loading = false;
                    this.offWhy = null;
                    activity = Date.now();
                    pending = { code: null, n: 0, at: 0 };
                    unsureSince = 0;
                    this.hard = false;
                    this.watchHidden();
                    this.loop(my);
                    this.listCameras(true);
                } catch (e) {
                    if (my === session) {
                        this.error = describeError(e);
                        await this.stop();
                    }
                } finally {
                    if (my === session) this.loading = false;
                }
            },

            // Read frames ~10 times per second, cropped to the middle of the picture
            async loop(my) {
                if (my !== session) return;
                const video = this.$refs.video;

                if (idleOff && !this.typing && Date.now() - activity > idleOff) {
                    this.offWhy = 'No scan for ' + Math.round(idleOff / 60000) + ' minutes: camera and flashlight off to save battery.';
                    this.stop();
                    return;
                }
                if (unsureSince && Date.now() - pending.at > 1500) unsureSince = 0; // nothing read for a while: not a hard label
                if (unsureSince && !this.hard && Date.now() - unsureSince > hardAfter) this.hard = true;

                if (video.readyState >= 2 && video.videoWidth && ++frame % 3 === 0) {
                    const light = brightness(video);
                    if (light < 40 && light >= 8 && this.torchSupported && !this.torchOn) {
                        dimSince = dimSince || Date.now();
                        if (Date.now() - dimSince > 1500) this.darkTip = true;
                    } else {
                        dimSince = 0;
                        this.darkTip = false;
                    }
                    if (light < 8) {
                        darkSince = darkSince || Date.now();
                        if (Date.now() - darkSince > 2500) {
                            darkSince = 0;
                            this.onBlackPicture(my);
                            return;
                        }
                    } else {
                        darkSince = 0;
                        if (this.hint) this.hint = null;
                    }
                }

                try {
                    if (detector && !this.paused && !this.typing && video.readyState >= 2 && video.videoWidth) {
                        const vw = video.videoWidth;
                        const vh = video.videoHeight;
                        const cw = Math.floor(vw * 0.92);
                        const ch = Math.floor(vh * (config.confirm > 1 ? 0.5 : 0.6));
                        const scale = Math.min(1, 1280 / cw);

                        canvas.width = Math.floor(cw * scale);
                        canvas.height = Math.floor(ch * scale);
                        ctx.drawImage(video, (vw - cw) / 2, (vh - ch) / 2, cw, ch, 0, 0, canvas.width, canvas.height);

                        const results = await detector.detect(canvas);
                        if (my === session && !this.paused && results && results.length) {
                            this.onRead(results[0].rawValue);
                        }
                    }
                } catch (e) {}

                if (my === session && this.scanning) {
                    loopTimer = setTimeout(() => this.loop(my), 100);
                }
            },

            // The picture stayed black: try the other cameras once each, then explain.
            async onBlackPicture(my) {
                await this.listCameras(true);
                let current = this.autoCam || this.cameraId;
                try { current = (stream && stream.getVideoTracks()[0].getSettings().deviceId) || current; } catch (e) {}
                tried.add(current || 'auto');
                // never the front camera, and not kept: the next start tries the back camera again
                const next = this.cameras.filter((c) => !isFront(c.label)).map((c) => c.id).find((id) => id && !tried.has(id));

                if (next && tried.size <= this.cameras.length) {
                    this.hint = 'The picture was black. Trying another back camera…';
                    this.autoCam = next;
                    await this.stop();
                    await this.start(true);
                    return;
                }

                this.hint = BLACK_TIP;
                if (my === session && this.scanning) this.loop(my); // keep reading in case the picture comes back
            },

            async stop() {
                if (this.torchOn) { try { localStorage.setItem(TORCH_KEY, String(Date.now())); } catch (e) {} }
                this.darkTip = false;
                session++;
                clearTimeout(loopTimer);
                clearInterval(watchTimer);
                loopTimer = null;
                watchTimer = null;

                if (stream) {
                    stream.getTracks().forEach((t) => t.stop());
                    stream = null;
                }
                if (this.$refs.video) this.$refs.video.srcObject = null;

                this.scanning = false;
                this.loading = false;
                this.torchOn = false;
            },

            async toggle() {
                if (this.scanning || this.loading) {
                    this.stoppedByUser = true;
                    clearTimeout(startTimer);
                    await this.stop();
                } else {
                    await this.start();
                }
            },

            async toggleTorch() {
                const track = stream && stream.getVideoTracks()[0];
                if (!track) return;
                try {
                    await track.applyConstraints({ advanced: [{ torch: !this.torchOn }] });
                    this.torchOn = !this.torchOn;
                    this.darkTip = false;
                    try { this.torchOn ? localStorage.setItem(TORCH_KEY, String(Date.now())) : localStorage.removeItem(TORCH_KEY); } catch (e) {}
                } catch (e) {}
            },

            async listCameras(force = false) {
                if (this.cameras.length && !force) return;
                try {
                    const devices = await navigator.mediaDevices.enumerateDevices(); // no permission popup
                    this.cameras = devices
                        .filter((d) => d.kind === 'videoinput')
                        .map((d, i) => ({ id: d.deviceId, label: d.label || `Camera ${i + 1}` }));
                } catch (e) {}
            },

            forgetCamera() {
                this.cameraId = null;
                try { localStorage.removeItem(CAMERA_KEY); } catch (e) {}
            },

            // 🔄 Switch camera: back cameras first, the front one last
            camChoices() {
                const backs = this.cameras.filter((c) => !isFront(c.label));
                const fronts = this.cameras.filter((c) => isFront(c.label));
                return [
                    ...backs.map((c, i) => ({ id: c.id, front: false, name: i ? 'Back camera ' + (i + 1) : 'Back camera',
                        sub: i ? (/wide|ultra/i.test(c.label) ? 'Wide · for big labels up close' : 'Another back camera') : 'Main · best for barcodes' })),
                    ...fronts.map((c, i) => ({ id: c.id, front: true, name: fronts.length > 1 ? 'Front camera ' + (i + 1) : 'Front camera', sub: 'Only if the back camera is broken' })),
                ];
            },
            backCamera() {
                const first = this.camChoices().find((c) => !c.front);
                this.useCamera(first ? first.id : null);
            },
            async useCamera(id) {
                this.camList = false;
                this.autoCam = null;
                this.cameraId = id || null;
                try { id ? localStorage.setItem(CAMERA_KEY, id) : localStorage.removeItem(CAMERA_KEY); } catch (e) {}
                await this.stop();
                await this.start();
            },

            // Backup: stop the camera if the modal closed and the observer missed it
            watchHidden() {
                clearInterval(watchTimer);
                watchTimer = setInterval(() => {
                    if (!root.isConnected || root.getClientRects().length === 0) this.stop();
                }, 1000);
            },

            // A read counts only when the same number is read again right after (blurry labels misread)
            onRead(text) {
                const code = String(text || '').trim();
                if (!code) return;
                const now = Date.now();
                if (code === this.lastCode && now - this.lastAt < (config.cooldown ?? 2500)) return;
                if (confirmReads <= 1) { this.onDetected(code); return; }
                if (pending.code === code && now - pending.at < 1500) {
                    pending.n++;
                    pending.at = now;
                    if (pending.n >= confirmReads) {
                        pending = { code: null, n: 0, at: 0 };
                        this.onDetected(code);
                    }
                    return;
                }
                pending = { code, n: 1, at: now };
                unsureSince = unsureSince || now;
            },

            setPaused(p) {
                this.paused = p;
                if (p) return;
                activity = Date.now();
                this.lastAt = Date.now(); // the box still in front of the camera is not read again at once
                pending = { code: null, n: 0, at: 0 };
                if (!this.scanning && !this.loading && config.autoStart && root.getClientRects().length) this.start();
            },

            // Hard to read: type the number on a keypad
            openTyping() { this.typing = true; this.typed = ''; this.hard = false; unsureSince = 0; activity = Date.now(); },
            closeTyping() { this.typing = false; this.typed = ''; activity = Date.now(); },
            key(k) {
                activity = Date.now();
                if (k === '⌫') this.typed = this.typed.slice(0, -1);
                else this.typed = (this.typed + k).slice(0, 20);
            },
            findTyped() {
                const code = this.typed.trim();
                if (!code) return;
                this.typing = false;
                this.typed = '';
                this.lastCode = code;
                this.lastAt = Date.now();
                this.submit(code);
            },

            async turnTorchOn() { if (!this.torchOn) await this.toggleTorch(); },

            // 📷 Take photo here: a still from the camera that is already on (no camera app)
            async snapPhoto() {
                const track = stream && stream.getVideoTracks()[0];
                const video = this.$refs.video;
                this.flash = true;
                setTimeout(() => { this.flash = false; }, 160);
                if (track && 'ImageCapture' in window) {
                    try {
                        const blob = await new window.ImageCapture(track).takePhoto();
                        if (blob && blob.size) return new File([blob], 'photo.jpg', { type: blob.type || 'image/jpeg' });
                    } catch (e) {}
                }
                if (!video || !video.videoWidth) return null;
                const c = document.createElement('canvas');
                c.width = video.videoWidth;
                c.height = video.videoHeight;
                c.getContext('2d').drawImage(video, 0, 0);
                const blob = await new Promise((r) => c.toBlob(r, 'image/jpeg', 0.9));
                return blob ? new File([blob], 'photo.jpg', { type: 'image/jpeg' }) : null;
            },

            onDetected(text) {
                const code = String(text || '').trim();
                if (!code) return;
                activity = Date.now();
                unsureSince = 0;
                this.hard = false;
                const now = Date.now();
                if (code === this.lastCode && now - this.lastAt < (config.cooldown ?? 2500)) return;

                this.lastCode = code;
                this.lastAt = now;

                this.flash = true;
                setTimeout(() => { this.flash = false; }, 600);

                if (navigator.vibrate) navigator.vibrate(80);
                if (config.beep !== false) beep();
                if (!config.continuous) this.stop();
                this.submit(code);
            },

            submitManual() {
                const code = this.manualCode.trim();
                if (!code) return;
                activity = Date.now();
                this.lastCode = code;
                this.lastAt = Date.now();
                this.submit(code);
            },

            submit(code) {
                this.manualCode = config.statePath ? code : '';
                if (config.statePath) this.$wire.set(config.statePath, code);
                if (config.method) this.$wire.call(config.method, code);
                this.$dispatch('barcode-scanned', { code });
            },
        };
    };
})();
