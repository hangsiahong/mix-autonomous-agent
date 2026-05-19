document.addEventListener('DOMContentLoaded', () => {
    const viewports = document.querySelectorAll('.viewport');
    const navBtns = document.querySelectorAll('.nav-btn');
    const coordX = document.getElementById('coord-x');
    const coordY = document.getElementById('coord-y');

    // Navigation Logic
    navBtns.forEach(btn => {
        btn.addEventListener('click', () => {
            const target = btn.getAttribute('data-target');
            
            // Update Active State
            viewports.forEach(vp => {
                vp.classList.remove('active');
                if (vp.id === target) {
                    vp.classList.add('active');
                }
            });

            // Log navigation to "console" feel
            console.log(`[SYSTEM] NAVIGATING_TO: ${target.toUpperCase()}`);
        });
    });

    // Coordinate Tracking
    window.addEventListener('mousemove', (e) => {
        const x = String(e.clientX).padStart(4, '0');
        const y = String(e.clientY).padStart(4, '0');
        coordX.innerText = `X: ${x}`;
        coordY.innerText = `Y: ${y}`;

        // Subtle Image Parallax for any active image
        const activeImg = document.querySelector('.viewport.active img');
        if (activeImg) {
            const moveX = (e.clientX - window.innerWidth / 2) * 0.01;
            const moveY = (e.clientY - window.innerHeight / 2) * 0.01;
            activeImg.style.transform = `translate(${moveX}px, ${moveY}px) scale(1.05)`;
        }
    });

    // Glitch Effect Randomizer
    const glitchTitle = document.querySelector('.glitch-title');
    if (glitchTitle) {
        setInterval(() => {
            if (Math.random() > 0.95) {
                glitchTitle.style.transform = `translate(${Math.random() * 10}px, ${Math.random() * 5}px)`;
                setTimeout(() => {
                    glitchTitle.style.transform = 'translate(0,0)';
                }, 50);
            }
        }, 100);
    }

    // Initialize
    console.log("ANGELIONA_OS LOADED. STABLE_BUILD_01.");
});
