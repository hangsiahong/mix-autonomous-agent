gsap.registerPlugin(ScrollTrigger);

// Initialize Lenis Smooth Scroll
const lenis = new Lenis();
lenis.on('scroll', ScrollTrigger.update);
gsap.ticker.add((time) => {
    lenis.raf(time * 1000);
});
gsap.ticker.lagSmoothing(0);

window.addEventListener('load', () => {
    // 0. Preloader Logic
    const preloaderTl = gsap.timeline();
    
    preloaderTl.to('.p-char', {
        opacity: 1,
        y: 0,
        stagger: 0.05,
        duration: 0.8,
        ease: 'power3.out'
    })
    .to('.preloader-bar', {
        width: '100%',
        duration: 1.5,
        ease: 'power4.inOut'
    }, '-=0.5')
    .to('.preloader', {
        yPercent: -100,
        duration: 1,
        ease: 'expo.inOut'
    })
    .add(() => {
        startHeroAnimation();
    }, '-=0.5');

    function startHeroAnimation() {
        const loadTl = gsap.timeline({
            defaults: { ease: 'power4.out', duration: 2 }
        });

        loadTl.to('.main-img-wrapper', {
            clipPath: 'inset(0% 0% 0% 0%)',
            duration: 2.5,
            ease: 'expo.inOut'
        })
        .from('.reveal-text', {
            y: 150,
            opacity: 0,
            skewY: 7,
            stagger: 0.1
        }, '-=1.8')
        .from('.nav', {
            y: -100,
            opacity: 0
        }, '-=1.5')
        .from('.hero-label, .hero-footer .fade-in', {
            y: 20,
            opacity: 0,
            stagger: 0.2
        }, '-=1.2');
    }

    // 1. Custom Cursor Logic
    const cursor = document.querySelector('.cursor');
    const follower = document.querySelector('.cursor-follower');
    
    document.addEventListener('mousemove', (e) => {
        gsap.to(cursor, { x: e.clientX, y: e.clientY, duration: 0 });
        gsap.to(follower, { x: e.clientX, y: e.clientY, duration: 0.3 });
    });

    const links = document.querySelectorAll('a, button, .p-item, .big-link');
    links.forEach(link => {
        link.addEventListener('mouseenter', () => {
            gsap.to(follower, { scale: 2.5, backgroundColor: 'rgba(197, 168, 128, 0.15)', duration: 0.3 });
        });
        link.addEventListener('mouseleave', () => {
            gsap.to(follower, { scale: 1, backgroundColor: 'transparent', duration: 0.3 });
        });
    });

    // 2. Horizontal Scroll
    const scrollContainer = document.querySelector('.h-scroll-container');
    if (scrollContainer && window.innerWidth > 900) {
        gsap.to(scrollContainer, {
            xPercent: -75,
            ease: "none",
            scrollTrigger: {
                trigger: ".horizontal-scroll",
                pin: true,
                scrub: 1,
                end: () => "+=" + scrollContainer.offsetWidth
            }
        });
    }

    // 3. Product Detail Interactivity
    const detailOverlay = document.querySelector('.detail-overlay');
    const closeDetail = document.querySelector('.close-detail');
    const productItems = document.querySelectorAll('.p-item');

    productItems.forEach(item => {
        item.addEventListener('click', () => {
            const imgSrc = item.querySelector('img').src;
            const title = item.querySelector('h3').innerText;
            detailOverlay.querySelector('img').src = imgSrc;
            detailOverlay.querySelector('.detail-title').innerText = title;
            detailOverlay.classList.add('active');
            lenis.stop();
        });
    });

    closeDetail.addEventListener('click', () => {
        detailOverlay.classList.remove('active');
        lenis.start();
    });

    // 4. Product Card Tilt Effect
    productItems.forEach(item => {
        item.addEventListener('mousemove', (e) => {
            const rect = item.getBoundingClientRect();
            const x = e.clientX - rect.left;
            const y = e.clientY - rect.top;
            const centerX = rect.width / 2;
            const centerY = rect.height / 2;
            const rotateX = (y - centerY) / 20;
            const rotateY = (centerX - x) / 20;
            
            gsap.to(item.querySelector('.p-img'), {
                rotateX: rotateX,
                rotateY: rotateY,
                duration: 0.5,
                ease: 'power2.out'
            });
        });
        
        item.addEventListener('mouseleave', () => {
            gsap.to(item.querySelector('.p-img'), {
                rotateX: 0,
                rotateY: 0,
                duration: 0.8,
                ease: 'elastic.out(1, 0.3)'
            });
        });
    });
});
