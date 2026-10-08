import { Details } from "./components/Details";
import { Faq } from "./components/Faq";
import { Features } from "./components/Features";
import { ClosingCta, Footer } from "./components/Footer";
import { Hero } from "./components/Hero";
import { Nav } from "./components/Nav";

export function App() {
  return (
    <>
      <Nav />
      <main>
        <Hero />
        <Features />
        <Details />
        <Faq />
        <ClosingCta />
      </main>
      <Footer />
    </>
  );
}
