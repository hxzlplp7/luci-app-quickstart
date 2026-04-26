(function(root, factory) {
    const api = factory();
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
    if (root) {
        root.DashboardData = api;
    }
})(typeof globalThis !== 'undefined' ? globalThis : this, function() {
    function toArray(value) {
        return Array.isArray(value) ? value : [];
    }

    function toPositiveNumber(value) {
        const number = Number(value);
        return Number.isFinite(number) && number > 0 ? number : 0;
    }

    function toRateNumber(value) {
        const number = Number(value);
        return Number.isFinite(number) && number >= 0 ? number : null;
    }

    function isLikelyDomain(value) {
        const domain = String(value || '').trim().toLowerCase();
        if (!domain || domain.length > 253 || !domain.includes('.') || /^\d+\.\d+\.\d+\.\d+$/.test(domain)) {
            return false;
        }

        const labels = domain.split('.');
        if (labels.length < 2) return false;

        for (const label of labels) {
            if (!label || label.length > 63 || !/^[a-z0-9-]+$/.test(label) || label.startsWith('-') || label.endsWith('-')) {
                return false;
            }
        }

        const tld = labels[labels.length - 1];
        if (!/^[a-z]/.test(tld)) return false;
        if (!tld.startsWith('xn--') && !/^[a-z-]+$/.test(tld)) return false;

        return labels.some((label) => /[a-z]/.test(label));
    }

    function filterDomainRows(rows) {
        return toArray(rows).filter((item) => item && isLikelyDomain(item.domain));
    }

    function pickActiveAppState(databus, oafData) {
        const databusApps = toArray(databus && databus.online_apps && databus.online_apps.list);
        const databusRecognition = (databus && databus.app_recognition) || {};
        const databusClassStats = toArray(databusRecognition.class_stats);
        const databusAvailable = Boolean(databusRecognition.available) || databusApps.length > 0 || databusClassStats.length > 0;

        if (databusAvailable) {
            return {
                apps: databusApps,
                classStats: databusClassStats,
                available: databusAvailable,
                source: databusRecognition.source || (databusApps[0] && databusApps[0].source) || 'databus',
                engine: databusRecognition.engine || '',
                featureVersion: databusRecognition.feature_version || '',
            };
        }

        const oafApps = toArray(oafData && oafData.active_apps);
        const oafClassStats = toArray(oafData && oafData.class_stats);
        return {
            apps: oafApps,
            classStats: oafClassStats,
            available: oafApps.length > 0 || oafClassStats.length > 0,
            source: (oafData && (oafData.active_source || oafData.source)) || 'oaf',
            engine: (oafData && oafData.engine) || '',
            featureVersion: (oafData && oafData.current_version) || '',
        };
    }

    function deriveTrafficSnapshot(sample, previousState, nowMs) {
        const nextState = {
            interface: sample && sample.interface ? String(sample.interface) : '',
            tx_bytes: toPositiveNumber(sample && sample.tx_bytes),
            rx_bytes: toPositiveNumber(sample && sample.rx_bytes),
            at: toPositiveNumber(nowMs),
        };

        const backendTxRate = toRateNumber(sample && sample.tx_rate);
        const backendRxRate = toRateNumber(sample && sample.rx_rate);
        if (backendTxRate !== null || backendRxRate !== null) {
            return {
                txRate: backendTxRate !== null ? backendTxRate : 0,
                rxRate: backendRxRate !== null ? backendRxRate : 0,
                nextState: nextState,
            };
        }

        if (!previousState || !previousState.interface || !nextState.interface || previousState.interface !== nextState.interface) {
            return {
                txRate: 0,
                rxRate: 0,
                nextState: nextState,
            };
        }

        const previousAt = toPositiveNumber(previousState.at);
        if (!previousAt || nextState.at <= previousAt) {
            return {
                txRate: 0,
                rxRate: 0,
                nextState: nextState,
            };
        }

        const txDelta = nextState.tx_bytes - toPositiveNumber(previousState.tx_bytes);
        const rxDelta = nextState.rx_bytes - toPositiveNumber(previousState.rx_bytes);
        if (txDelta < 0 || rxDelta < 0) {
            return {
                txRate: 0,
                rxRate: 0,
                nextState: nextState,
            };
        }

        const diffSeconds = (nextState.at - previousAt) / 1000;
        if (!(diffSeconds > 0)) {
            return {
                txRate: 0,
                rxRate: 0,
                nextState: nextState,
            };
        }

        return {
            txRate: txDelta / diffSeconds,
            rxRate: rxDelta / diffSeconds,
            nextState: nextState,
        };
    }

    return {
        pickActiveAppState: pickActiveAppState,
        deriveTrafficSnapshot: deriveTrafficSnapshot,
        isLikelyDomain: isLikelyDomain,
        filterDomainRows: filterDomainRows,
    };
});
