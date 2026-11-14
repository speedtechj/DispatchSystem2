(function () {
    // ZXing (WebAssembly) barcode decoder — used when the phone has no built-in BarcodeDetector (e.g. iPhone)
    const PONYFILL_URL = 'https://fastly.jsdelivr.net/npm/barcode-detector@3/dist/iife/ponyfill.min.js';
    const CAMERA_KEY = 'bb-scanner-camera';

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

        return {
            scanning: false,
            loading: false,
            error: null,
            lastCode: null,
            lastAt: 0,
            manualCode: '',
            cameras: [],
            cameraId: null,
            stoppedByUser: false,
            flash: false,
            torchSupported: false,
            torchOn: false,

            init() {
                try { this.cameraId = localStorage.getItem(CAMERA_KEY) || null; } catch (e) {}

                onVisibilityChange = () => {
                    if (document.hidden) {
                        this.stop();
                    } else if (config.autoStart && !this.stoppedByUser && this.$el.getClientRects().length) {
                        this.start();
                    }
                };
                document.addEventListener('visibilitychange', onVisibilityChange);

                // Start when the scanner becomes visible (modal opened), stop when hidden (modal closed)
                if ('IntersectionObserver' in window) {
                    observer = new IntersectionObserver((entries) => {
                        const entry = entries[entries.length - 1];
                        entry.isIntersecting ? this.onShown() : this.onHidden();
                    }, { threshold: 0.01 });
                    observer.observe(this.$el);
                } else if (config.autoStart) {
                    setTimeout(() => this.start(), 300);
                }
            },

            destroy() {
                document.removeEventListener('visibilitychange', onVisibilityChange);
                if (observer) observer.disconnect();
                clearTimeout(startTimer);
                this.stop();
            },

            onShown() {
                this.stoppedByUser = false;
                if (!config.autoStart) return;
                clearTimeout(startTimer);
                startTimer = setTimeout(() => this.start(), 300); // let the modal finish opening
            },

            onHidden() {
                clearTimeout(startTimer);
                this.stop();
            },

            async start() {
                if (this.scanning || this.loading) return;
                this.error = null;
                this.stoppedByUser = false;

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

                    const base = { width: { ideal: 1920 }, height: { ideal: 1080 } };
                    let s;
                    try {
                        s = await navigator.mediaDevices.getUserMedia({
                            audio: false,
                            video: this.cameraId
                                ? { ...base, deviceId: { exact: this.cameraId } }
                                : { ...base, facingMode: { ideal: 'environment' } },
                        });
                    } catch (e) {
                        if (!this.cameraId || e.name === 'NotAllowedError') throw e;
                        this.forgetCamera(); // saved camera no longer exists → use back camera
                        s = await navigator.mediaDevices.getUserMedia({
                            audio: false,
                            video: { ...base, facingMode: { ideal: 'environment' } },
                        });
                    }

                    if (my !== session) { s.getTracks().forEach((t) => t.stop()); return; }
                    stream = s;

                    const video = this.$refs.video;
                    video.muted = true;
                    video.setAttribute('muted', '');
                    video.setAttribute('playsinline', '');
                    video.srcObject = stream;
                    try { await video.play(); } catch (e) {}
                    await waitForVideo(video);

                    const track = stream.getVideoTracks()[0];
                    try { await track.applyConstraints({ advanced: [{ focusMode: 'continuous' }] }); } catch (e) {}
                    try {
                        const caps = track.getCapabilities ? track.getCapabilities() : {};
                        this.torchSupported = !!caps.torch;
                    } catch (e) { this.torchSupported = false; }
                    this.torchOn = false;

                    detector = await detectorPromise;
                    if (my !== session) return;

                    this.scanning = true;
                    this.loading = false;
                    this.watchHidden();
                    this.loop(my);
                    this.listCameras();
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

                try {
                    if (detector && video.readyState >= 2 && video.videoWidth) {
                        const vw = video.videoWidth;
                        const vh = video.videoHeight;
                        const cw = Math.floor(vw * 0.9);
                        const ch = Math.floor(vh * 0.6);
                        const scale = Math.min(1, 1280 / cw);

                        canvas.width = Math.floor(cw * scale);
                        canvas.height = Math.floor(ch * scale);
                        ctx.drawImage(video, (vw - cw) / 2, (vh - ch) / 2, cw, ch, 0, 0, canvas.width, canvas.height);

                        const results = await detector.detect(canvas);
                        if (my === session && results && results.length) {
                            this.onDetected(results[0].rawValue);
                        }
                    }
                } catch (e) {}

                if (my === session && this.scanning) {
                    loopTimer = setTimeout(() => this.loop(my), 100);
                }
            },

            async stop() {
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
                } catch (e) {}
            },

            async listCameras() {
                if (this.cameras.length) return;
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

            async useCamera(id) {
                this.cameraId = id || null;
                try { id ? localStorage.setItem(CAMERA_KEY, id) : localStorage.removeItem(CAMERA_KEY); } catch (e) {}
                if (this.scanning) { await this.stop(); await this.start(); }
            },

            // Backup: stop the camera if the modal closed and the observer missed it
            watchHidden() {
                clearInterval(watchTimer);
                watchTimer = setInterval(() => {
                    if (!this.$el.isConnected || this.$el.getClientRects().length === 0) this.stop();
                }, 1000);
            },

            onDetected(text) {
                const code = String(text || '').trim();
                if (!code) return;
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
